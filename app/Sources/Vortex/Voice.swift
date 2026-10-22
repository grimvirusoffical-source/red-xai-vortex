import SwiftUI
import AVFoundation

/// Voice calls: whisper.cpp (speech → text) and Piper (text → speech), both on this Mac.
/// Falls back to the built-in macOS voice when Piper isn't installed. Push-to-talk or hands-free (voice activity detection).
@MainActor final class VoiceEngine: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = VoiceEngine()
    @Published var state = "Idle"          // Idle | Listening | Transcribing | Thinking | Speaking
    @Published var level: Float = 0
    @Published var transcript: [(String, String)] = []
    @Published var handsFree = false
    @Published var setupLog = ""
    @Published var installing = false

    var dir: URL { let d = ChatStore.dir.appendingPathComponent("voice", isDirectory: true); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }
    var whisperBin: String? { ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    var whisperModel: String { dir.appendingPathComponent(UserDefaults.standard.string(forKey: "whisperModel") ?? "ggml-base.en.bin").path }
    var piperBin: String { dir.appendingPathComponent("piper-venv/bin/piper").path }
    var piperVoice: String { dir.appendingPathComponent(UserDefaults.standard.string(forKey: "piperVoice") ?? "en_US-lessac-medium.onnx").path }
    var sttReady: Bool { whisperBin != nil && FileManager.default.fileExists(atPath: whisperModel) }
    var piperReady: Bool { FileManager.default.isExecutableFile(atPath: piperBin) && FileManager.default.fileExists(atPath: piperVoice) }

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var recording = false
    private var lastVoice = Date()
    private var heardVoice = false
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var onSpoken: (() -> Void)?
    var send: ((String) async -> String?)?     // set by the call view: sends text to chat, returns the reply

    // MARK: capture
    func startListening() {
        guard !recording else { return }
        stopSpeaking()
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in
                guard ok else { self.state = "Microphone access denied (System Settings → Privacy → Microphone)"; return }
                self.beginCapture()
            }
        }
    }
    private func beginCapture() {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: fmt, to: target) else { state = "Audio format error"; return }
        samples = []; heardVoice = false; lastVoice = Date()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            let ratio = 16000 / fmt.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16) else { return }
            var fed = false
            conv.convert(to: out, error: nil) { _, st in if fed { st.pointee = .noDataNow; return nil }; fed = true; st.pointee = .haveData; return buf }
            let n = Int(out.frameLength); guard n > 0, let p = out.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: p, count: n))
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(n))
            Task { @MainActor in self?.feed(chunk, rms: rms) }
        }
        do { try engine.start(); recording = true; state = "Listening" } catch { state = "Mic error: \(error.localizedDescription)" }
    }
    private func feed(_ chunk: [Float], rms: Float) {
        guard recording else { return }
        samples += chunk; level = min(1, rms * 12)
        let threshold = Float(UserDefaults.standard.object(forKey: "vadThreshold") as? Double ?? 0.015)
        if rms > threshold { lastVoice = Date(); heardVoice = true }
        // hands-free: end of utterance after 1.2 s of silence
        if handsFree && heardVoice && Date().timeIntervalSince(lastVoice) > 1.2 { finishListening() }
        if samples.count > 16000 * 60 { finishListening() }    // 60 s cap
    }
    func finishListening() {
        guard recording else { return }
        recording = false; engine.inputNode.removeTap(onBus: 0); engine.stop(); level = 0
        let audio = samples; samples = []
        guard audio.count > 16000 / 3, heardVoice || !handsFree else { if handsFree { startListening() } else { state = "Idle" }; return }
        Task { await self.process(audio) }
    }
    func cancelListening() { recording = false; engine.inputNode.removeTap(onBus: 0); engine.stop(); samples = []; level = 0; state = "Idle" }

    // MARK: pipeline
    private func process(_ audio: [Float]) async {
        state = "Transcribing"
        do {
            let text = try await transcribe(audio)
            guard !text.isEmpty else { state = "Didn't catch that"; if handsFree { startListening() }; return }
            transcript.append(("You", text))
            state = "Thinking"
            let reply = await send?(text) ?? ""
            if !reply.isEmpty { transcript.append(("Vortex", reply)); await speak(reply) }
            if handsFree { startListening() } else { state = "Idle" }
        } catch { state = "Error: \(error.localizedDescription)"; if handsFree { startListening() } }
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        guard let bin = whisperBin else { throw err("whisper.cpp is not installed. Voice → Set up.") }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("vortex-\(UUID().uuidString).wav")
        try Self.writeWAV(audio, to: wav); defer { try? FileManager.default.removeItem(at: wav) }
        let out = try await IntegrationStore.shared.runProcess(bin, ["-m", whisperModel, "-f", wav.path, "-nt", "-np", "-l", "auto", "-t", "6"], env: [:], timeout: 120)
        guard out.status == 0 else { throw err("whisper exit \(out.status): \(out.stderr.suffix(200))") }
        return out.stdout.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func speak(_ text: String) async {
        let t = Self.speakable(text)
        guard !t.isEmpty else { return }
        state = "Speaking"
        if piperReady, let wav = try? await piper(t) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                onSpoken = { c.resume() }
                player = try? AVAudioPlayer(contentsOf: wav); player?.delegate = self
                if player?.play() != true { onSpoken = nil; c.resume() }
            }
        } else {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                onSpoken = { c.resume() }
                synth.delegate = self
                let u = AVSpeechUtterance(string: t); u.rate = 0.5
                synth.speak(u)
            }
        }
    }
    func stopSpeaking() { player?.stop(); synth.stopSpeaking(at: .immediate); let f = onSpoken; onSpoken = nil; f?() }
    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) { Task { @MainActor in let f = self.onSpoken; self.onSpoken = nil; f?() } }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { Task { @MainActor in let f = self.onSpoken; self.onSpoken = nil; f?() } }

    func piper(_ text: String) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("vortex-tts-\(UUID().uuidString).wav")
        let txt = FileManager.default.temporaryDirectory.appendingPathComponent("vortex-tts-\(UUID().uuidString).txt")
        try text.write(to: txt, atomically: true, encoding: .utf8); defer { try? FileManager.default.removeItem(at: txt) }
        let r = try await IntegrationStore.shared.runProcess("/bin/zsh", ["-c", "\"$0\" --model \"$1\" --output_file \"$2\" < \"$3\"", piperBin, piperVoice, out.path, txt.path], env: [:], timeout: 120)
        guard r.status == 0, FileManager.default.fileExists(atPath: out.path) else { throw err("piper failed: \(r.stderr.suffix(200))") }
        return out
    }

    /// Strip markdown/code so it reads naturally.
    static func speakable(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "(?s)```.*?```", with: " (code omitted) ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_`#>|]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        return String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2500))
    }
    static func writeWAV(_ f: [Float], to url: URL) throws {
        var d = Data(); let sr: UInt32 = 16000, n = UInt32(f.count)
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + n * 2); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(sr); u32(sr * 2); u16(2); u16(16); d.append("data".data(using: .ascii)!); u32(n * 2)
        for s in f { var v = Int16(max(-1, min(1, s)) * 32767).littleEndian; d.append(Data(bytes: &v, count: 2)) }
        try d.write(to: url)
    }
    func err(_ m: String) -> NSError { NSError(domain: "Vortex", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }

    // MARK: setup (Homebrew whisper.cpp + model, Piper venv + voice)
    func install() async {
        installing = true; setupLog = ""
        let v = dir.path
        let steps: [(String, String)] = [
            ("whisper.cpp", "command -v whisper-cli >/dev/null || /opt/homebrew/bin/brew install whisper-cpp"),
            ("Whisper model (base.en, 148 MB)", "cd '\(v)' && [ -s ggml-base.en.bin ] || curl -fL -o ggml-base.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"),
            ("Piper", "cd '\(v)' && { [ -x piper-venv/bin/piper ] || { PY=$(command -v python3.11 || command -v python3.12 || command -v python3); \"$PY\" -m venv piper-venv && ./piper-venv/bin/pip install -q piper-tts; }; }"),
            ("Piper voice (lessac, 60 MB)", "cd '\(v)' && [ -s en_US-lessac-medium.onnx ] || { curl -fL -o en_US-lessac-medium.onnx https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx && curl -fL -o en_US-lessac-medium.onnx.json https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json; }"),
        ]
        for (name, cmd) in steps {
            setupLog += "• \(name)… "
            let r = try? await IntegrationStore.shared.runProcess("/bin/zsh", ["-lc", cmd], env: [:], timeout: 1200)
            setupLog += (r?.status == 0 ? "ok\n" : "failed: \(r?.combined.suffix(200) ?? "")\n")
        }
        installing = false
    }
}

struct VoiceCallView: View {
    @EnvironmentObject var store: ChatStore
    @StateObject var ve = VoiceEngine.shared
    @Environment(\.dismiss) var dismiss
    let sendText: (String) -> Void
    var body: some View {
        VStack(spacing: 14) {
            HStack { Text("Voice call").font(.title2.bold()); Spacer(); Text(ve.piperReady ? "Piper voice" : "macOS voice").font(.caption).foregroundStyle(.secondary) }
            if !ve.sttReady {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Voice needs whisper.cpp (speech recognition) on this Mac. Piper (natural voice) is optional; without it the macOS voice is used.").font(.callout)
                    Button(ve.installing ? "Setting up…" : "Set up voice (Homebrew + downloads)") { Task { await ve.install() } }.disabled(ve.installing)
                    if !ve.setupLog.isEmpty { Text(ve.setupLog).font(.caption.monospaced()) }
                }
            }
            ScrollViewReader { pr in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(ve.transcript.enumerated()), id: \.offset) { i, t in
                            (Text(t.0 + ": ").bold() + Text(t.1)).id(i).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: ve.transcript.count) { _, n in pr.scrollTo(n - 1) }
            }.frame(height: 220).padding(8).background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            ProgressView(value: Double(ve.level)).tint(.red)
            Text(ve.state).font(.headline).foregroundStyle(ve.state.hasPrefix("Error") || ve.state.contains("denied") ? .red : .primary)
            Toggle("Hands-free (talk naturally; it listens again after each reply)", isOn: $ve.handsFree)
                .onChange(of: ve.handsFree) { _, on in if on { ve.startListening() } else { ve.cancelListening() } }
            if !ve.handsFree {
                Text("Hold to talk").font(.caption).foregroundStyle(.secondary)
                Circle().fill(ve.state == "Listening" ? Color.red : Color.accentColor).frame(width: 84, height: 84)
                    .overlay(Image(systemName: "mic.fill").font(.largeTitle).foregroundStyle(.white))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in if ve.state != "Listening" { ve.startListening() } }.onEnded { _ in ve.finishListening() })
                    .disabled(!ve.sttReady)
            }
            HStack {
                Button("Stop speaking") { ve.stopSpeaking() }.disabled(ve.state != "Speaking")
                Spacer()
                Button("End call", role: .destructive) { ve.handsFree = false; ve.cancelListening(); ve.stopSpeaking(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear {
            ve.send = { text in
                await MainActor.run { sendText(text) }
                // wait for the reply to finish
                try? await Task.sleep(nanoseconds: 300_000_000)
                while await MainActor.run(body: { store.streaming }) { try? await Task.sleep(nanoseconds: 200_000_000) }
                return await MainActor.run { store.current?.messages.last(where: { $0.role == "assistant" })?.content ?? "" }
            }
        }
    }
}
