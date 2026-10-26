import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Media generation with exact specs (image, speech/TTS, music, sound effects, short video),
/// a local library, in-chat generation (/image, /speech, /music, /sfx, /video) and a viewer
/// showing dimensions / format / quality with Download, Regenerate and Redesign.
struct MediaJob: Identifiable, Decodable {
    let id: String
    let type: String?
    let status: String?
    let progress: Double?
    let position: Int?
    let seconds: Double?
}

struct MediaSpec: Codable, Equatable {
    var type = "image"
    var prompt = ""
    var style = ""
    var size = "512x512"
    var quality = "standard"   // draft | standard | high
    var format = "png"         // image: png | jpeg ; audio: wav ; video: mp4
    var duration: Double = 8
    var speed: Double = 1
    var frames = 16

    static let types = ["image", "speech", "music", "sfx", "video"]
    var steps: Int { ["draft": 4, "standard": 8, "high": 20][quality] ?? 8 }
    var jpegQ: Int { ["draft": 70, "standard": 85, "high": 95][quality] ?? 85 }

    mutating func normalize() throws {
        type = type.lowercased(); prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.types.contains(type) else { throw MediaErr.msg("type must be image, speech, music, sfx or video") }
        guard !prompt.isEmpty else { throw MediaErr.msg("prompt required") }
        if !["draft", "standard", "high"].contains(quality) { quality = "standard" }
        switch type {
        case "image":
            let p = size.lowercased().split(separator: "x").compactMap { Int($0) }
            guard p.count == 2, (256...1024).contains(p[0]), (256...1024).contains(p[1]) else { throw MediaErr.msg("image size must be WxH, 256–1024 per side") }
            size = "\(p[0] / 64 * 64)x\(p[1] / 64 * 64)"
            format = (format == "jpeg" || format == "jpg") ? "jpeg" : "png"
        case "video":
            format = "mp4"; size = "256x256"
            guard (8...24).contains(frames) else { throw MediaErr.msg("video frames must be 8–24 (8 fps)") }
        default:
            format = "wav"
            if type == "music", !(1...30).contains(duration) { duration = 8 }
            if type == "sfx", !(1...10).contains(duration) { duration = 5 }
            if type == "speech", !(0.5...2).contains(speed) { speed = 1 }
        }
    }
    var gatewayBody: [String: Any] {
        var p = prompt; if !style.isEmpty && type != "speech" { p += ", \(style) style" }
        var b: [String: Any] = ["type": type, "prompt": p]
        switch type {
        case "image": b["size"] = size; b["steps"] = steps
        case "video": b["frames"] = frames
        case "speech": b["input"] = p; b["speed"] = speed
        default: b["duration"] = duration
        }
        return b
    }
    var commandLine: String {
        var s = "/\(type) \(prompt)"
        switch type {
        case "image": s += " --size \(size) --quality \(quality) --format \(format)"
        case "video": s += " --frames \(frames)"
        case "speech": s += " --speed \(speed)"
        default: s += " --duration \(Int(duration))"
        }
        if !style.isEmpty { s += " --style \"\(style)\"" }
        return s
    }
    /// Parses "/image a fox --size 768x512 --quality high --style \"oil paint\" --format jpeg".
    static func parse(_ text: String) -> MediaSpec? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/") else { return nil }
        let head = String(t.dropFirst().prefix { !$0.isWhitespace }).lowercased()
        let alias = ["img": "image", "tts": "speech", "say": "speech", "sound": "sfx"]
        let ty = alias[head] ?? head
        guard types.contains(ty) else { return nil }
        var spec = MediaSpec(); spec.type = ty
        var rest = String(t.dropFirst(head.count + 1))
        let re = try! NSRegularExpression(pattern: #"--(size|quality|style|format|duration|speed|frames)\s+(?:"([^"]*)"|'([^']*)'|(\S+))"#, options: .caseInsensitive)
        let ns = rest as NSString
        for m in re.matches(in: rest, range: NSRange(location: 0, length: ns.length)).reversed() {
            let k = ns.substring(with: m.range(at: 1)).lowercased()
            var v = ""
            for g in 2...4 where m.range(at: g).location != NSNotFound { v = ns.substring(with: m.range(at: g)) }
            switch k {
            case "size": spec.size = v
            case "quality": spec.quality = v.lowercased()
            case "style": spec.style = v
            case "format": spec.format = v.lowercased()
            case "duration": spec.duration = Double(v) ?? spec.duration
            case "speed": spec.speed = Double(v) ?? spec.speed
            default: spec.frames = Int(v) ?? spec.frames
            }
            rest = (rest as NSString).replacingCharacters(in: m.range, with: "")
        }
        spec.prompt = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return spec
    }
}

enum MediaErr: LocalizedError { case msg(String); var errorDescription: String? { if case .msg(let s) = self { return s }; return nil } }

struct MediaItem: Codable, Identifiable, Equatable {
    var id: String
    var spec: MediaSpec
    var status = "queued"
    var progress: Double = 0
    var position = 0
    var file: String? = nil
    var mime: String? = nil
    var info: [String: String] = [:]   // width, height, format, quality, steps, jpegQuality, sampleRate, channels, bitDepth, duration, fps, frames, bytes
    var error: String? = nil
    var created = Date()
    var chatID: UUID? = nil
    var url: URL? { file.map { URL(fileURLWithPath: $0) } }
    var done: Bool { status == "done" }
    var failed: Bool { status == "failed" || status == "error" }

    var summary: String {
        var p: [String] = []
        if let w = info["width"], let h = info["height"] { p.append("\(w)×\(h)px") }
        p.append(info["format"] ?? spec.format.uppercased())
        if spec.type == "image" { p.append("\(spec.quality) quality (\(info["steps"] ?? "\(spec.steps)") steps" + (info["jpegQuality"].map { ", JPEG q\($0)" } ?? "") + ")") }
        else { p.append("\(spec.quality) quality") }
        if let d = info["duration"] { p.append("\(d)s") }
        if let r = info["sampleRate"] { p.append("\(r) Hz \(info["bitDepth"] ?? "16")-bit \(info["channels"] == "2" ? "stereo" : "mono")") }
        if let f = info["fps"] { p.append("\(info["frames"] ?? "") frames @ \(f) fps") }
        if !spec.style.isEmpty { p.append("style: \(spec.style)") }
        if let b = info["bytes"], let n = Double(b) { p.append(n > 1_048_576 ? String(format: "%.1f MB", n / 1_048_576) : String(format: "%.0f KB", n / 1024)) }
        return p.joined(separator: " · ")
    }
}

@MainActor final class MediaLibrary: ObservableObject {
    static let shared = MediaLibrary()
    @Published var items: [String: MediaItem] = [:]
    @Published var message = ""
    private var polling = Set<String>()

    static var dir: URL {
        let d = ChatStore.dir.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var index: URL { Self.dir.appendingPathComponent("library.json") }

    init() {
        if let d = try? Data(contentsOf: index), let l = try? JSONDecoder().decode([String: MediaItem].self, from: d) { items = l }
        for (id, it) in items where !it.done && !it.failed { poll(id) }
    }
    private func save() { if let d = try? JSONEncoder().encode(items) { try? d.write(to: index, options: .atomic) } }
    var sorted: [MediaItem] { items.values.sorted { $0.created > $1.created } }

    private func req(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard let s = ServerStore.shared.active, let u = URL(string: s.chatURL + path) else { return nil }
        var r = URLRequest(url: u); r.httpMethod = method; r.timeoutInterval = 60
        r.setValue("Bearer \(ServerStore.shared.key(for: s))", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }

    /// Queues a generation with an exact spec. With a chat, posts the command and a live viewer into it.
    @discardableResult
    func submit(_ s: MediaSpec, chat: ChatStore? = nil, chatID: UUID? = nil) async -> String? {
        var spec = s
        do { try spec.normalize() } catch { message = error.localizedDescription; post(chat, chatID, spec.commandLine, "Media: \(error.localizedDescription)"); return nil }
        guard let r = req("/jobs", method: "POST", body: spec.gatewayBody) else { message = "No active server"; post(chat, chatID, spec.commandLine, "Media: no active server"); return nil }
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300, let id = j["id"] as? String, !id.isEmpty else {
                let m = "Failed: HTTP \(code)"; message = m; post(chat, chatID, spec.commandLine, "Media: \(m)"); return nil }
            var it = MediaItem(id: id, spec: spec); it.position = j["position"] as? Int ?? 0; it.chatID = chatID
            items[id] = it; save()
            message = "Queued \(id) (position \(it.position))"
            post(chat, chatID, spec.commandLine, "[[media:\(id)]]")
            poll(id)
            return id
        } catch { message = error.localizedDescription; post(chat, chatID, spec.commandLine, "Media: \(error.localizedDescription)"); return nil }
    }
    private func post(_ chat: ChatStore?, _ chatID: UUID?, _ user: String, _ reply: String) {
        guard let chat, let i = chat.idx(chatID) else { return }
        chat.chats[i].messages.append(Message(role: "user", content: user))
        chat.chats[i].messages.append(Message(role: "assistant", content: reply))
        if chat.chats[i].title == "New Chat" { chat.chats[i].title = String(user.prefix(40)) }
        chat.chats[i].updated = Date(); chat.save()
    }

    func regenerate(_ id: String, chat: ChatStore? = nil) async {
        guard let it = items[id] else { return }
        await submit(it.spec, chat: chat, chatID: it.chatID)
    }
    func redesign(_ id: String, spec: MediaSpec, chat: ChatStore? = nil) async {
        await submit(spec, chat: chat, chatID: items[id]?.chatID)
    }

    func poll(_ id: String) {
        guard !polling.contains(id) else { return }
        polling.insert(id)
        Task { @MainActor in
            defer { self.polling.remove(id) }
            for _ in 0..<1200 {
                await self.refresh(id)
                guard let it = self.items[id], !it.done, !it.failed else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func refresh(_ id: String) async {
        guard var it = items[id], let r = req("/jobs/" + id),
              let (d, resp) = try? await URLSession.shared.data(for: r),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        if (resp as? HTTPURLResponse)?.statusCode == 404 { it.status = "failed"; it.error = "job expired on server"; items[id] = it; save(); return }
        it.status = o["status"] as? String ?? it.status
        it.progress = (o["progress"] as? Double) ?? Double(o["progress"] as? Int ?? Int(it.progress))
        it.position = o["position"] as? Int ?? 0
        if it.failed { it.error = o["error"] as? String }
        if it.done {
            guard let res = o["result"] as? [String: Any], let b = res["b64"] as? String, var data = Data(base64Encoded: b), !data.isEmpty else {
                it.status = "failed"; it.error = "empty result"; items[id] = it; save(); return }
            var mime = res["mime"] as? String ?? ""
            it.info = Self.convert(it.spec, &data, &mime)
            let ext = ["image/png": "png", "image/jpeg": "jpg", "audio/wav": "wav", "video/mp4": "mp4"][mime] ?? "bin"
            let f = Self.dir.appendingPathComponent("\(id).\(ext)")
            try? data.write(to: f); it.file = f.path; it.mime = mime
        }
        items[id] = it; save()
    }

    /// Applies the requested output format and measures the real result.
    static func convert(_ s: MediaSpec, _ data: inout Data, _ mime: inout String) -> [String: String] {
        var info = ["format": s.format.uppercased(), "quality": s.quality]
        if mime.hasPrefix("image/"), let rep = NSBitmapImageRep(data: data) {
            info["width"] = "\(rep.pixelsWide)"; info["height"] = "\(rep.pixelsHigh)"; info["steps"] = "\(s.steps)"
            if s.format == "jpeg", let j = rep.representation(using: .jpeg, properties: [.compressionFactor: Double(s.jpegQ) / 100]) {
                data = j; mime = "image/jpeg"; info["jpegQuality"] = "\(s.jpegQ)"
            }
        } else if mime == "audio/wav", data.count > 44 {
            func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
            func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
            let ch = u16(22), rate = u32(24), bits = u16(34)
            info["sampleRate"] = "\(rate)"; info["channels"] = "\(ch)"; info["bitDepth"] = "\(bits)"
            let bps = rate * ch * bits / 8
            if bps > 0 { info["duration"] = String(format: "%.1f", Double(data.count - 44) / Double(bps)) }
        } else if mime == "video/mp4" {
            info["width"] = "256"; info["height"] = "256"; info["fps"] = "8"; info["frames"] = "\(s.frames)"
            info["duration"] = String(format: "%.1f", Double(s.frames) / 8)
        }
        info["bytes"] = "\(data.count)"
        return info
    }

    func download(_ id: String) {
        guard let it = items[id], let src = it.url else { return }
        let p = NSSavePanel(); p.nameFieldStringValue = "vortex-\(it.spec.type)-\(id).\(src.pathExtension)"
        p.begin { r in if r == .OK, let dst = p.url { try? FileManager.default.removeItem(at: dst); try? FileManager.default.copyItem(at: src, to: dst) } }
    }
}

/// Spec controls shared by the Media tab and the Redesign sheet.
struct MediaSpecFields: View {
    @Binding var spec: MediaSpec
    var body: some View {
        HStack {
            TextField("Style (e.g. watercolor, photorealistic)", text: $spec.style)
            Picker("Quality", selection: $spec.quality) { Text("Draft").tag("draft"); Text("Standard").tag("standard"); Text("High").tag("high") }.frame(width: 160)
        }
        HStack {
            switch spec.type {
            case "image":
                Picker("Size", selection: $spec.size) { ForEach(["256x256", "512x512", "768x768", "1024x1024", "768x512", "512x768", "1024x576", "576x1024"], id: \.self) { Text($0).tag($0) } }.frame(width: 180)
                Picker("Format", selection: $spec.format) { Text("PNG").tag("png"); Text("JPEG").tag("jpeg") }.frame(width: 150)
            case "video":
                Stepper("Frames: \(spec.frames) (\(String(format: "%.1f", Double(spec.frames) / 8))s @ 8 fps, 256×256 MP4)", value: $spec.frames, in: 8...24)
            case "speech":
                Stepper("Speed: \(String(format: "%.1f", spec.speed))× (WAV)", value: $spec.speed, in: 0.5...2, step: 0.1)
            default:
                Stepper("Duration: \(Int(spec.duration))s (WAV)", value: $spec.duration, in: 1...(spec.type == "sfx" ? 10 : 30), step: 1)
            }
            Spacer()
        }
    }
}

/// Viewer card: the media, its real dimensions/format/quality, and Download / Regenerate / Redesign.
struct MediaCard: View {
    let id: String
    var chat: ChatStore? = nil
    @ObservedObject var lib = MediaLibrary.shared
    @Local var redesigning = false
    @Local var draft = MediaSpec()
    var body: some View {
        if let it = lib.items[id] {
            VStack(alignment: .leading, spacing: 6) {
                if it.done, let u = it.url {
                    if it.spec.type == "image", let img = NSImage(contentsOf: u) {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 480, maxHeight: 420).clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        HStack { Image(systemName: it.spec.type == "video" ? "film" : "waveform").font(.title); Button("Play") { NSWorkspace.shared.open(u) } }
                    }
                    Text("\(it.spec.type) · \(it.summary)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("“\(it.spec.prompt)”").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    HStack {
                        Button("Download") { lib.download(id) }
                        Button("Regenerate") { Task { await lib.regenerate(id, chat: chat) } }
                        Button("Redesign") { draft = it.spec; redesigning = true }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                    }.controlSize(.small)
                } else if it.failed {
                    Text("\(it.spec.type) failed: \(it.error ?? "")").foregroundStyle(.red).font(.caption)
                    Button("Regenerate") { Task { await lib.regenerate(id, chat: chat) } }.controlSize(.small)
                } else {
                    HStack { Text(it.spec.type).bold(); Text(it.status).foregroundStyle(.secondary); if it.position > 0 { Text("#\(it.position) in queue").font(.caption).foregroundStyle(.secondary) } }
                    Text(it.spec.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    ProgressView(value: min(max(it.progress, 0), 100), total: 100).tint(.red).frame(maxWidth: 360)
                }
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            .onAppear { if !it.done && !it.failed { lib.poll(id) } }
            .sheet(isPresented: $redesigning) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Redesign \(draft.type)").font(.headline)
                    TextField("Prompt", text: $draft.prompt, axis: .vertical).lineLimit(2...5)
                    MediaSpecFields(spec: $draft)
                    HStack { Spacer(); Button("Cancel") { redesigning = false }
                        Button("Generate") { let s = draft; redesigning = false; Task { await lib.redesign(id, spec: s, chat: chat) } }.keyboardShortcut(.defaultAction) }
                }.padding().frame(width: 520)
            }
        } else {
            Text("Media \(id) is not in this Mac's library.").font(.caption).foregroundStyle(.secondary)
        }
    }
    static func mediaID(_ content: String) -> String? {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("[[media:"), t.hasSuffix("]]") else { return nil }
        return String(t.dropFirst(8).dropLast(2))
    }
}

struct MediaJobsView: View {
    @ObservedObject var lib = MediaLibrary.shared
    @Local var spec = MediaSpec()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $spec.type) {
                    Text("Image").tag("image"); Text("Speech (TTS)").tag("speech"); Text("Music").tag("music")
                    Text("Sound effect").tag("sfx"); Text("Short video").tag("video")
                }.frame(width: 160)
                TextField("Prompt (or text to speak)…", text: $spec.prompt).onSubmit { go() }
                Button("Generate") { go() }.disabled(spec.prompt.isEmpty).keyboardShortcut(.defaultAction)
            }
            MediaSpecFields(spec: $spec)
            Text("Tip: in any chat type /image a red fox --size 768x512 --quality high --style watercolor --format jpeg (also /speech, /music --duration 12, /sfx, /video --frames 24).")
                .font(.caption).foregroundStyle(.secondary)
            if !lib.message.isEmpty { Text(lib.message).font(.caption).foregroundStyle(.secondary) }
            ScrollView { LazyVStack(alignment: .leading, spacing: 10) { ForEach(lib.sorted) { MediaCard(id: $0.id) } } }
        }
        .padding()
    }
    private func go() { let s = spec; Task { await lib.submit(s) } }
}
