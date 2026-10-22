import Foundation

/// Runs models on this Mac with llama.cpp (Metal). Starts llama-server only when a local model
/// is used, and stops it after a few idle minutes and when the app quits. Nothing stays in the background.
@MainActor
final class LocalRuntime: ObservableObject {
    static let shared = LocalRuntime()
    static let port = 18190
    @Published var models: [String] = []           // ids (file stems / dirs)
    @Published var jobs: [String: (done: Double, total: Double, state: String)] = [:]
    @Published var running: String?
    private var proc: Process?
    private var lastUse = Date()
    private var idleTimer: Timer?
    private var downloads: [String: URLSessionDownloadTask] = [:]

    static var dir: URL {
        let d = ChatStore.dir.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    init() { scan() }

    func scan() {
        let fm = FileManager.default
        models = ((try? fm.contentsOfDirectory(atPath: Self.dir.path)) ?? []).filter { !$0.hasPrefix(".") && !$0.hasSuffix(".part") }
            .map { $0.hasSuffix(".gguf") ? String($0.dropLast(5)) : $0 }.sorted()
    }
    func bytes(_ id: String) -> Double {
        let fm = FileManager.default
        let f = Self.dir.appendingPathComponent(id + ".gguf")
        if let a = try? fm.attributesOfItem(atPath: f.path) { return (a[.size] as? Double) ?? 0 }
        let d = Self.dir.appendingPathComponent(id)
        return ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).reduce(0) { $0 + (((try? fm.attributesOfItem(atPath: d.appendingPathComponent($1).path))?[.size] as? Double) ?? 0) }
    }
    var binary: String? {
        let cands: [String?] = [Bundle.main.url(forResource: "llama-server", withExtension: nil)?.path, "/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        return cands.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    var freeDisk: Double {
        ((try? Self.dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage).map(Double.init) ?? 0
    }
    var ram: Double { Double(ProcessInfo.processInfo.physicalMemory) }

    // MARK: downloads
    /// files: [(url, destName)]; multimodal models go into a directory.
    func download(id: String, files: [(URL, String)], asDir: Bool) {
        guard jobs[id]?.state != "downloading" else { return }
        jobs[id] = (0, 1, "downloading")
        Task {
            do {
                var total = 0.0
                for (u, _) in files {
                    var r = URLRequest(url: u); r.httpMethod = "HEAD"
                    if let (_, resp) = try? await URLSession.shared.data(for: r), let h = resp as? HTTPURLResponse { total += Double(h.expectedContentLength) }
                }
                if total > 0 && total + 5e9 > freeDisk { throw NSError(domain: "Vortex", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not enough disk space on this Mac"]) }
                if total * 1.1 > ram * 0.75 { throw NSError(domain: "Vortex", code: 2, userInfo: [NSLocalizedDescriptionKey: "Too big for this Mac's memory"]) }
                jobs[id] = (0, max(total, 1), "downloading")
                var doneBefore = 0.0
                let target = asDir ? Self.dir.appendingPathComponent(id) : Self.dir
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for (u, name) in files {
                    let (bytes, resp) = try await URLSession.shared.bytes(from: u)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    let part = target.appendingPathComponent(name + ".part")
                    FileManager.default.createFile(atPath: part.path, contents: nil)
                    let h = try FileHandle(forWritingTo: part)
                    var buf = Data(); buf.reserveCapacity(1 << 20); var n = 0.0; var last = Date()
                    for try await b in bytes {
                        buf.append(b)
                        if buf.count >= 1 << 20 {
                            try h.write(contentsOf: buf); n += Double(buf.count); buf.removeAll(keepingCapacity: true)
                            if Date().timeIntervalSince(last) > 0.5 { jobs[id] = (doneBefore + n, max(total, 1), "downloading"); last = Date() }
                        }
                    }
                    try h.write(contentsOf: buf); n += Double(buf.count); try h.close()
                    doneBefore += n
                    let dst = target.appendingPathComponent(name)
                    try? FileManager.default.removeItem(at: dst)
                    try FileManager.default.moveItem(at: part, to: dst)
                }
                jobs[id] = (doneBefore, doneBefore, "done"); scan()
            } catch {
                jobs[id] = (0, 1, "error: \(error.localizedDescription)")
                let fm = FileManager.default
                for f in (try? fm.contentsOfDirectory(atPath: Self.dir.path)) ?? [] where f.hasSuffix(".part") { try? fm.removeItem(at: Self.dir.appendingPathComponent(f)) }
            }
        }
    }
    func pullHF(id: String, repo: String, file: String, mmproj: String?) {
        let base = "https://huggingface.co/\(repo)/resolve/main/"
        if let mm = mmproj { download(id: id, files: [(URL(string: base + file)!, file), (URL(string: base + mm)!, mm)], asDir: true) }
        else { download(id: id, files: [(URL(string: base + file)!, id + ".gguf")], asDir: false) }
    }
    func pullOllama(ref: String) {
        let parts = ref.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0], tag = parts.count > 1 ? parts[1] : "latest"
        let ns = name.contains("/") ? "" : "library/"
        let id = ("ol-" + name.replacingOccurrences(of: "/", with: "-") + "-" + tag).lowercased().replacingOccurrences(of: "_", with: "-")
        Task {
            do {
                let reg = "https://registry.ollama.ai/v2/\(ns)\(name)"
                var r = URLRequest(url: URL(string: "\(reg)/manifests/\(tag)")!)
                r.setValue("application/vnd.docker.distribution.manifest.v2+json", forHTTPHeaderField: "Accept")
                let (d, _) = try await URLSession.shared.data(for: r)
                let layers = ((try JSONSerialization.jsonObject(with: d) as? [String: Any])?["layers"] as? [[String: Any]]) ?? []
                func dig(_ kind: String) -> String? { layers.first { ($0["mediaType"] as? String)?.hasSuffix("." + kind) == true }?["digest"] as? String }
                guard let m = dig("model") else { jobs[id] = (0, 1, "error: no model layer"); return }
                if let p = dig("projector") {
                    download(id: id, files: [(URL(string: "\(reg)/blobs/\(m)")!, "model.gguf"), (URL(string: "\(reg)/blobs/\(p)")!, "mmproj-model.gguf")], asDir: true)
                } else { download(id: id, files: [(URL(string: "\(reg)/blobs/\(m)")!, id + ".gguf")], asDir: false) }
            } catch { jobs[id] = (0, 1, "error: \(error.localizedDescription)") }
        }
    }
    func remove(_ id: String) -> Double {
        if running == id { stop() }
        let b = bytes(id)
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(id + ".gguf"))
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(id))
        jobs[id] = nil; scan(); return b
    }

    // MARK: on-demand runtime
    /// Ensures llama-server is serving `id`; returns the OpenAI base URL.
    func ensure(_ id: String) async throws -> String {
        lastUse = Date()
        let base = "http://127.0.0.1:\(Self.port)/v1"
        if running == id, proc?.isRunning == true { return base }
        stop()
        guard let bin = binary else { throw NSError(domain: "Vortex", code: 3, userInfo: [NSLocalizedDescriptionKey: "llama-server not found (bundled or Homebrew)"]) }
        var args = ["--host", "127.0.0.1", "--port", "\(Self.port)", "-ngl", "99", "-c", "8192", "--jinja", "--alias", id]
        let f = Self.dir.appendingPathComponent(id + ".gguf"), d = Self.dir.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: f.path) { args += ["-m", f.path] }
        else {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
            guard let m = files.first(where: { !$0.hasPrefix("mmproj") && $0.hasSuffix(".gguf") }) else { throw URLError(.fileDoesNotExist) }
            args += ["-m", d.appendingPathComponent(m).path]
            if let mm = files.first(where: { $0.hasPrefix("mmproj") }) { args += ["--mmproj", d.appendingPathComponent(mm).path] }
        }
        if id.contains("embed") || id.hasPrefix("bge") { args.append("--embeddings") }
        let p = Process(); p.executableURL = URL(fileURLWithPath: bin); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); proc = p; running = id
        for _ in 0..<240 {
            if let (_, r) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(Self.port)/health")!), (r as? HTTPURLResponse)?.statusCode == 200 { break }
            if !p.isRunning { running = nil; throw NSError(domain: "Vortex", code: 4, userInfo: [NSLocalizedDescriptionKey: "Local model failed to start"]) }
            try await Task.sleep(for: .milliseconds(500))
        }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in let s = LocalRuntime.shared; if Date().timeIntervalSince(s.lastUse) > 300 { s.stop() } }
        }
        return base
    }
    func touch() { lastUse = Date() }
    func stop() {
        idleTimer?.invalidate(); idleTimer = nil
        if let p = proc, p.isRunning { p.terminate() }
        proc = nil; running = nil
    }
}
