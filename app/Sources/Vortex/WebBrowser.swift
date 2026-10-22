import Foundation
import Network
import AppKit

extension Admin {
    static func call(on s: ServerDef, _ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        await ServerStore.shared.ensureTunnel(s)
        let key = await ServerStore.shared.key(for: s)
        guard let u = URL(string: "http://127.0.0.1:\(s.localPort)" + path) else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = method; r.timeoutInterval = 120
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(DeviceID.value, forHTTPHeaderField: DeviceID.header)
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        var lastErr: Error = URLError(.cannotConnectToHost)
        for _ in 0..<5 {   // tunnel may still be coming up
            do {
                let (d, resp) = try await URLSession.shared.data(for: r)
                let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
                if let h = resp as? HTTPURLResponse, h.statusCode >= 300 {
                    if h.statusCode == 403, (j["banned"] as? Bool == true) || ((j["error"] as? [String: Any])?["message"] as? String)?.contains("banned") == true {
                        await MainActor.run { OwnerWipe.run() }
                    }
                    throw NSError(domain: "Vortex", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: ((j["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(h.statusCode)"])
                }
                return j
            } catch let e as URLError { lastErr = e; try? await Task.sleep(for: .milliseconds(800)) }
        }
        throw lastErr
    }
}

/// Local-only model browser at http://127.0.0.1:<port>/?t=<session token>.
@MainActor
final class ModelBrowserServer {
    static let shared = ModelBrowserServer()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    let token: String = {
        var b = [UInt8](repeating: 0, count: 24); _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }()
    var url: URL? { port == 0 ? nil : URL(string: "http://127.0.0.1:\(port)/?t=\(token)") }

    func open(page: String? = nil) {
        start()
        Task { for _ in 0..<20 { if let u = url { NSWorkspace.shared.open(page.flatMap { URL(string: u.absoluteString + "&page=" + $0) } ?? u); return }; try? await Task.sleep(for: .milliseconds(100)) } }
    }
    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { return }
        l.stateUpdateHandler = { [weak self] st in
            if case .ready = st { Task { @MainActor in self?.port = l.port?.rawValue ?? 0 } }
        }
        l.newConnectionHandler = { c in Task { @MainActor in ModelBrowserServer.shared.handle(c) } }
        l.start(queue: .main); listener = l
    }
    func stop() { listener?.cancel(); listener = nil; port = 0 }

    private func handle(_ c: NWConnection) {
        c.start(queue: .main)
        var buf = Data()
        func readMore() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, err in
                if let d { buf.append(d) }
                if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(data: buf[..<r.lowerBound], encoding: .utf8) ?? ""
                    let len = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                    if buf.count - r.upperBound >= len || done || err != nil {
                        let body = buf[r.upperBound...].prefix(len)
                        Task { @MainActor in
                            let (code, ctype, out) = await self.route(head: head, body: Data(body))
                            var resp = "HTTP/1.1 \(code) OK\r\nContent-Type: \(ctype)\r\nContent-Length: \(out.count)\r\nCache-Control: no-store\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n".data(using: .utf8)!
                            resp.append(out)
                            c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
                        }
                        return
                    }
                }
                if done || err != nil || buf.count > 1 << 22 { c.cancel(); return }
                readMore()
            }
        }
        readMore()
    }

    private func pluginsJSON() -> [String: Any] {
        let enc = JSONEncoder()
        func arr(_ l: [PluginManifest]) -> [Any] { l.compactMap { (try? enc.encode($0)).flatMap { try? JSONSerialization.jsonObject(with: $0) } } }
        return ["store": arr(PluginCatalog.starters), "installed": arr(PluginStore.shared.installed), "enabled": Array(PluginStore.shared.enabled)]
    }
    private func json(_ o: Any, _ code: Int = 200) -> (Int, String, Data) {
        (code, "application/json", (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8))
    }

    private func route(head: String, body: Data) async -> (Int, String, Data) {
        let first = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: String(parts[1])) else { return json(["error": "bad request"], 400) }
        let method = String(parts[0]), path = comps.path
        var q: [String: String] = [:]; comps.queryItems?.forEach { q[$0.name] = $0.value }
        let hdrToken = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("x-token:") }.map { $0.dropFirst(8).trimmingCharacters(in: .whitespaces) }
        // Host check blocks DNS-rebinding; token blocks other local apps/sites.
        let host = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("host:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) } ?? ""
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else { return json(["error": "forbidden"], 403) }
        guard (q["t"] ?? hdrToken) == token else { return (403, "text/plain", Data("Forbidden: open the browser from Red-XAI Vortex.".utf8)) }
        if path == "/" { return (200, "text/html; charset=utf-8", Data(BrowserPage.html.utf8)) }
        if method == "POST", hdrToken != token { return json(["error": "token header required"], 403) }
        let inb = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let ss = ServerStore.shared, lr = LocalRuntime.shared
        let target = (q["target"] ?? inb["target"] as? String) ?? ss.activeID
        let srv = ss.server(target) ?? ss.active
        do {
            switch (method, path) {
            case ("GET", "/x/targets"):
                var t: [[String: Any]] = ss.servers.map { ["id": $0.id, "name": "\($0.name) (\($0.sshHost.split(separator: "@").last ?? ""))", "kind": "server", "active": $0.id == ss.activeID] }
                t.append(["id": "local", "name": "This Mac (Metal, \(Int(lr.ram / 1e9)) GB RAM)", "kind": "local", "active": false])
                return json(["targets": t])
            case ("GET", "/x/catalog"):
                guard let s = ss.active else { return json(["catalog": []]) }
                var c = try await Admin.call(on: s, "GET", "/admin/catalog")
                if target == "local" {
                    let local = Set(lr.models)
                    c["catalog"] = (c["catalog"] as? [[String: Any]] ?? []).map { var m = $0; m["installed"] = local.contains(m["id"] as? String ?? ""); m["fits"] = ((m["ram_bytes"] as? Double) ?? 0) < lr.ram * 0.75; return m }
                } else if let s2 = srv, s2.id != s.id { c = try await Admin.call(on: s2, "GET", "/admin/catalog") }
                return json(c)
            case ("GET", "/x/ollama"):
                guard let s = ss.active else { return json(["library": []]) }
                return json(try await Admin.call(on: s, "GET", "/admin/ollama/library"))
            case ("GET", "/x/tags"):
                guard let s = ss.active else { return json(["tags": []]) }
                let n = (q["name"] ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                return json(try await Admin.call(on: s, "GET", "/admin/ollama/tags?name=\(n)"))
            case ("GET", "/x/installed"):
                if target == "local" {
                    return json(["installed": lr.models.map { ["id": $0, "bytes": lr.bytes($0), "category": "local"] }, "disk_free": lr.freeDisk])
                }
                guard let s = srv else { return json(["installed": []]) }
                return json(try await Admin.call(on: s, "GET", "/admin/models"))
            case ("GET", "/x/jobs"):
                if target == "local" { return json(["jobs": lr.jobs.map { ["id": $0.key, "done": $0.value.done, "total": $0.value.total, "state": $0.value.state] }]) }
                guard let s = srv else { return json(["jobs": []]) }
                return json(try await Admin.call(on: s, "GET", "/admin/jobs"))
            case ("POST", "/x/pull"):
                let kind = inb["kind"] as? String ?? "catalog"
                if target == "local" {
                    if kind == "ollama", let ref = inb["ref"] as? String { lr.pullOllama(ref: ref) }
                    else if let m = inb["model"] as? [String: Any], let id = m["id"] as? String, let repo = m["repo"] as? String, let file = m["file"] as? String {
                        lr.pullHF(id: id, repo: repo, file: file, mmproj: m["mmproj"] as? String)
                    } else { return json(["error": "this model has no download source"], 400) }
                    return json(["ok": true])
                }
                guard let s = srv else { return json(["error": "no server"], 400) }
                if kind == "ollama" { return json(try await Admin.call(on: s, "POST", "/admin/ollama/pull", ["ref": inb["ref"] ?? ""])) }
                return json(try await Admin.call(on: s, "POST", "/admin/models/pull", ["id": inb["id"] ?? ""]))
            case ("POST", "/x/remove"):
                let id = inb["id"] as? String ?? ""
                if target == "local" { return json(["ok": true, "freed_bytes": lr.remove(id)]) }
                guard let s = srv, id.range(of: "^[a-z0-9._-]+$", options: .regularExpression) != nil else { return json(["error": "bad id"], 400) }
                let r = try await Admin.call(on: s, "DELETE", "/admin/models/\(id)")
                Task { await ChatStoreRef.refresh() }
                return json(r)
            case ("GET", "/x/plugins"):
                return json(pluginsJSON())
            case ("POST", "/x/plugin-install"):
                guard let id = inb["id"] as? String, let p = PluginCatalog.starters.first(where: { $0.id == id }) else { return json(["error": "unknown plugin"], 404) }
                try PluginStore.shared.install(p); return json(pluginsJSON())
            case ("POST", "/x/plugin-remove"):
                PluginStore.shared.remove(inb["id"] as? String ?? ""); return json(pluginsJSON())
            case ("POST", "/x/plugin-toggle"):
                PluginStore.shared.setEnabled(inb["id"] as? String ?? "", inb["on"] as? Bool ?? false); return json(pluginsJSON())
            case ("GET", "/x/merges"):
                guard let s = ss.active else { return json(["merges": []]) }
                return json(try await Admin.call(on: s, "GET", "/admin/merges"))
            case ("POST", "/x/merge-add"):
                guard let s = ss.active, let name = inb["merge"] as? String, let model = inb["model"] as? String else { return json(["error": "merge and model required"], 400) }
                let all = try await Admin.call(on: s, "GET", "/admin/merges")
                guard var m = (all["merges"] as? [[String: Any]])?.first(where: { $0["name"] as? String == name }) else { return json(["error": "no such merge"], 404) }
                var models = m["models"] as? [String] ?? []
                if inb["as"] as? String == "judge" { m["judge"] = model }
                else if !models.contains(model) { models.append(model); m["models"] = models }
                let r = try await Admin.call(on: s, "POST", "/admin/merges", m)
                Task { await ChatStoreRef.refresh() }
                return json(r)
            default:
                return json(["error": "not found"], 404)
            }
        } catch { return json(["error": error.localizedDescription], 502) }
    }
}
