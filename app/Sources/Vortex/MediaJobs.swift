import SwiftUI

/// Media job queue (image, speech, music, sound effects, short video) with live progress.
struct MediaJob: Identifiable, Decodable {
    let id: String
    let type: String?
    let status: String?
    let progress: Double?
    let position: Int?
    let seconds: Double?
}

@MainActor final class MediaJobsModel: ObservableObject {
    @Published var jobs: [MediaJob] = []
    @Published var message = ""
    @Published var outputs: [String: URL] = [:]
    private var timer: Timer?

    private func req(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard let s = ServerStore.shared.active, let u = URL(string: s.chatURL + path) else { return nil }
        var r = URLRequest(url: u); r.httpMethod = method; r.timeoutInterval = 30
        r.setValue("Bearer \(ServerStore.shared.key(for: s))", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }

    func submit(type: String, prompt: String) async {
        var body: [String: Any] = ["type": type, "prompt": prompt]
        if type == "speech" { body["input"] = prompt }
        guard let r = req("/jobs", method: "POST", body: body) else { message = "No active server"; return }
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
            if (resp as? HTTPURLResponse)?.statusCode == 202 {
                message = "Queued \(j["id"] as? String ?? "") (position \(j["position"] as? Int ?? 0))"
            } else { message = "Failed: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)" }
        } catch { message = error.localizedDescription }
        await refresh()
    }

    func refresh() async {
        guard let r = req("/jobs") else { return }
        struct L: Decodable { let data: [MediaJob] }
        guard let (d, _) = try? await URLSession.shared.data(for: r), let l = try? JSONDecoder().decode(L.self, from: d) else { return }
        jobs = l.data
        for j in l.data where j.status == "done" && outputs[j.id] == nil { await fetch(j.id) }
    }

    private func fetch(_ id: String) async {
        guard let r = req("/jobs/" + id), let (d, _) = try? await URLSession.shared.data(for: r),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let res = o["result"] as? [String: Any], let b = res["b64"] as? String, let data = Data(base64Encoded: b) else { return }
        let mime = res["mime"] as? String ?? ""
        let ext = mime.contains("png") ? "png" : mime.contains("wav") ? "wav" : mime.contains("mp4") ? "mp4" : mime.contains("mpeg") ? "mp3" : "bin"
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Vortex Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("\(id).\(ext)")
        try? data.write(to: f); outputs[id] = f
    }

    func start() { timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in Task { @MainActor in await self.refresh() } } }
    func stop() { timer?.invalidate(); timer = nil }
}

struct MediaJobsView: View {
    @StateObject private var m = MediaJobsModel()
    @Local var type = "image"
    @Local var prompt = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $type) {
                    Text("Image").tag("image"); Text("Speech").tag("speech"); Text("Music").tag("music")
                    Text("Sound effect").tag("sfx"); Text("Short video").tag("video")
                }.frame(width: 150)
                TextField("Prompt (or text to speak)…", text: $prompt).onSubmit { go() }
                Button("Queue") { go() }.disabled(prompt.isEmpty).keyboardShortcut(.defaultAction)
            }
            if !m.message.isEmpty { Text(m.message).font(.caption).foregroundStyle(.secondary) }
            List(m.jobs) { j in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(j.type ?? "job").bold()
                        Text(j.status ?? "").foregroundStyle(.secondary)
                        if let p = j.position, p > 0 { Text("#\(p) in queue").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let s = j.seconds { Text(String(format: "%.1fs", s)).font(.caption.monospacedDigit()) }
                    }
                    ProgressView(value: min(max(j.progress ?? 0, 0), 100), total: 100).tint(.red)
                    if let f = m.outputs[j.id] {
                        HStack {
                            if f.pathExtension == "png", let img = NSImage(contentsOf: f) { Image(nsImage: img).resizable().scaledToFit().frame(height: 96) }
                            Button("Open") { NSWorkspace.shared.open(f) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                        }
                    }
                }.padding(.vertical, 2)
            }
        }
        .padding()
        .onAppear { m.start(); Task { await m.refresh() } }
        .onDisappear { m.stop() }
    }
    private func go() { let t = type, p = prompt; Task { await m.submit(type: t, prompt: p) } }
}
