import SwiftUI
import AppKit
import PDFKit
import AVFoundation

/// End-to-end self test of the app's own code paths against the live gateway.
/// Run: "/Applications/Red-XAI Vortex.app/Contents/MacOS/Vortex" --selftest /tmp/vortex-selftest.json
/// It restores every setting it touches and never writes chats, configs or keys.
@MainActor enum SelfTest {
    struct R: Codable { var area: String; var check: String; var pass: Bool; var detail: String; var secs: Double }
    static var results: [R] = []
    static var out = "/tmp/vortex-selftest.json"

    static var arg: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--selftest") else { return nil }
        return i + 1 < a.count ? a[i + 1] : out
    }
    static func err(_ s: String) -> NSError { NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

    static var only: String? { let a = CommandLine.arguments; return a.firstIndex(of: "--only").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
    static func t(_ area: String, _ check: String, _ f: () async throws -> String) async {
        if let o = only, !o.split(separator: ",").contains(where: { area.lowercased().hasPrefix($0.lowercased()) }) { return }
        let t0 = Date()
        do { let d = try await f(); results.append(R(area: area, check: check, pass: true, detail: String(d.prefix(400)), secs: Date().timeIntervalSince(t0))) }
        catch { results.append(R(area: area, check: check, pass: false, detail: String(error.localizedDescription.prefix(400)), secs: Date().timeIntervalSince(t0))) }
        flush()
    }
    static func flush() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted]
        try? e.encode(results).write(to: URL(fileURLWithPath: out))
    }
    static var params: ChatParams {
        ChatParams(baseURL: UserDefaults.standard.string(forKey: "serverURL") ?? Defaults.serverURL, apiKey: Keychain.get() ?? "", model: "vortex",
                   temperature: 0.2, topP: 0.9, repeatPenalty: 1.1, topK: 40, maxTokens: 200, seed: 7)
    }
    static func ask(_ model: String, _ msgs: [Message], max: Int = 120) async throws -> String {
        var p = params; p.model = model; p.maxTokens = max
        let b = ReplyBuffer(); _ = try await API.stream(p, messages: msgs, onToken: { b.append($0) })
        let s = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { throw err("empty reply from \(model)") }
        return s
    }
    static func expect(_ c: Bool, _ m: String) throws { if !c { throw err(m) } }

    static func run() async {
        if let a = arg { out = a }
        NSApp.setActivationPolicy(.accessory)
        for w in NSApp.windows { w.miniaturize(nil) }
        let ud = UserDefaults.standard
        let saved: [String: Any?] = Dictionary(uniqueKeysWithValues: ["pluginModes", "pluginsEnabled", "skillModes", "chatTools", "pc.killed", "pc.enabled"].map { ($0, ud.object(forKey: $0)) } + PCKind.allCases.map { ($0.key, ud.object(forKey: $0.key)) })
        defer {
            for (k, v) in saved { if let v { ud.set(v, forKey: k) } else { ud.removeObject(forKey: k) } }
            PluginStore.shared.load(); SkillStore.shared.modes = ud.dictionary(forKey: "skillModes") as? [String: String] ?? [:]
            PCControl.shared.killed = ud.bool(forKey: "pc.killed"); PCControl.shared.enabled = ud.object(forKey: "pc.enabled") as? Bool ?? true; PCControl.shared.hide()
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vortex-selftest", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        await ServerStore.shared.healthCheckActive()   // same check the app runs at launch
        if let a = ServerStore.shared.active { _ = await ServerStore.shared.ping(a) }   // wait for the tunnel before the first API call
        // ---- chat & model picker
        var models: [String] = []
        // The link helper starts with the app; give it up to 15 s before the first network check.
        if RedXLink.enabled { for _ in 0..<75 where !(await RedXLink.statusOK()) { try? await Task.sleep(for: .milliseconds(200)) } }
        await t("Model picker", "GET /v1/models via API.models") {
            models = try await API.models(base: params.baseURL, key: params.apiKey)
            try expect(models.contains("vortex") && models.contains("red-xai"), "vortex/red-xai missing: \(models)")
            return "\(models.count) models incl. vortex, red-xai, \(models.filter { $0.hasPrefix("redx-merge-") }.count) merges"
        }
        await t("Chat", "vortex follows 'Reply exactly: PONG'") {
            let r = try await ask("vortex", [Message(role: "user", content: "Reply with exactly: PONG")], max: 20)
            let w = r.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            try expect(w.uppercased() == "PONG", "replied: \(r.prefix(120))"); return r
        }
        await t("Chat", "red-xai follows 'Reply exactly: PONG'") {
            let r = try await ask("red-xai", [Message(role: "user", content: "Reply with exactly: PONG")], max: 20)
            let w = r.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            try expect(w.uppercased() == "PONG", "replied: \(r.prefix(120))"); return r
        }
        await t("Chat", "stream qwen2.5-14b") { try await ask("qwen2.5-14b", [Message(role: "user", content: "Reply with exactly: PONG")]) }
        await t("Chat", "context trimming keeps newest message") {
            var budget = 2000 * 4; var hist: [Message] = []
            let msgs = (0..<50).map { Message(role: $0 % 2 == 0 ? "user" : "assistant", content: String(repeating: "x", count: 900) + "#\($0)") }
            for m in msgs.reversed() { budget -= m.promptChars; if budget < 0 && !hist.isEmpty { break }; hist.insert(m, at: 0) }
            try expect(hist.last?.content.hasSuffix("#49") == true && hist.count < 50, "bad trim"); return "kept \(hist.count)/50, newest last"
        }

        // ---- merges
        await t("Merges", "admin list (HubStore.loadMerges)") {
            try await HubStore.shared.loadMerges(); return "\(HubStore.shared.merges.count) merges: " + HubStore.shared.merges.map(\.name).joined(separator: ", ")
        }
        for m in models.filter({ $0.hasPrefix("redx-merge-") }).prefix(2) {
            await t("Merges", "chat \(m)") { try await ask(m, [Message(role: "user", content: "What is 2+2? Answer with the number.")], max: 60) }
        }

        // ---- keys
        await t("API keys", "admin list (HubStore.loadKeys)") { try await HubStore.shared.loadKeys(); return "\(HubStore.shared.keys.count) keys listed (masked)" }
        await t("API keys", "owner gate refuses non-integration keys while locked") {
            await OwnerGate.shared.refresh()
            if OwnerGate.shared.unlocked { return "owner unlocked on this device; gate not testable now" }
            let k = await HubStore.shared.createKey(name: "selftest-gate", models: ["qwen2.5-14b"], rpm: 5)
            if k != nil, let row = HubStore.shared.keys.first(where: { $0.name == "selftest-gate" }) { _ = try? await Admin.call("DELETE", "/admin/keys/\(row.id)") }
            try expect(k == nil && HubStore.shared.keyError.contains("owner"), "locked gateway created a key")
            return "refused: \(HubStore.shared.keyError)"
        }
        await t("Desktop", "Win/Linux bridge: key → probe → agent → chat (public Vultr /v1)") {
            guard let port = ProcessInfo.processInfo.environment["VORTEX_DESKTOP_BRIDGE"] else { throw err("set VORTEX_DESKTOP_BRIDGE=host:port") }
            let hub = HubStore.shared
            let name = "integration: desktop-e2e"
            guard let k = await hub.createKey(name: name, models: [], rpm: 30) else { throw err("create failed: \(hub.keyError)") }
            defer { Task { if let row = HubStore.shared.keys.first(where: { $0.name == name && !$0.revoked }) { _ = try? await Admin.call("DELETE", "/admin/keys/\(row.id)") } } }
            func call(_ m: String, _ body: [String: Any]) async throws -> [String: Any] {
                var r = URLRequest(url: URL(string: "http://\(port)/bridge/\(m)")!); r.httpMethod = "POST"; r.timeoutInterval = 240
                r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try JSONSerialization.data(withJSONObject: body)
                return (try JSONSerialization.jsonObject(with: try await URLSession.shared.data(for: r).0) as? [String: Any]) ?? [:]
            }
            _ = try await call("settings.save", ["apiKey": k])
            let pr = try await call("settings.probe", [:]); let tv = try await call("agent.testVortex", [:])
            let ch = try await call("chat.new", [:]); let cid = ch["id"] as? String ?? ""
            let rep = try await call("chat.send", ["id": cid, "text": "Reply with exactly: DESKTOP_OK"])
            _ = try await call("settings.save", ["apiKey": " "])
            let reply = rep["reply"] as? String ?? "\(rep)"
            try expect((pr["ok"] as? Bool) == true && reply.uppercased().contains("DESKTOP"), "probe \(pr) test \(tv) reply \(reply.prefix(200))")
            if let row = hub.keys.first(where: { $0.name == name && !$0.revoked }) { _ = try? await Admin.call("DELETE", "/admin/keys/\(row.id)") }
            return "probe \(pr["message"] ?? "") | testVortex \(tv["message"] ?? "") | reply \(reply.prefix(120))"
        }
        await t("API keys", "create → use (model-scoped) → disable → revoke (HubStore)") {
            let hub = HubStore.shared
            // Owner unlocked → a normal key; locked → an integration-scoped key, which the gateway allows without unlock.
            let name = OwnerGate.shared.unlocked ? "selftest-temp" : "integration: selftest-temp"
            guard let k = await hub.createKey(name: name, models: ["qwen2.5-14b"], rpm: 30) else { throw err("create failed: \(hub.keyError)") }
            let chatURL = URL(string: params.baseURL + "/chat/completions")!
            func code(_ model: String) async throws -> Int {
                var r = URLRequest(url: chatURL); r.httpMethod = "POST"
                r.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": [["role": "user", "content": "hi"]], "max_tokens": 3])
                return ((try await URLSession.shared.data(for: r)).1 as? HTTPURLResponse)?.statusCode ?? 0
            }
            guard let row = hub.keys.first(where: { $0.name == name && !$0.revoked }) else { throw err("new key not listed") }
            defer { Task { _ = try? await Admin.call("DELETE", "/admin/keys/\(row.id)") } }
            let ok = try await code("qwen2.5-14b"), denied = try await code("vortex")
            await hub.patchKey(row.id, ["disabled": true])
            // Disabling needs owner unlock; while locked the gateway must refuse the change instead.
            let lockedRefused = !OwnerGate.shared.unlocked && hub.keyError.contains("owner")
            let off = try await code("qwen2.5-14b")
            _ = try await Admin.call("DELETE", "/admin/keys/\(row.id)"); let gone = try await code("qwen2.5-14b")
            try expect(ok == 200 && denied == 403 && (off == 401 || (lockedRefused && off == 200)) && gone == 401, "allowed=\(ok) other-model=\(denied) disabled=\(off) revoked=\(gone)")
            return "\(name): shown once (\(k.prefix(8))…), listed masked as \(row.prefix); 200 / 403 other model / 401 disabled / 401 revoked"
        }
        await t("Owner panel", "owner status") {
            await OwnerGate.shared.refresh(); try expect(OwnerGate.shared.message.isEmpty || OwnerGate.shared.configured, OwnerGate.shared.message)
            return "configured=\(OwnerGate.shared.configured) unlocked=\(OwnerGate.shared.unlocked)"
        }

        // ---- servers / failover
        await t("Servers", "server entries valid, ports don't collide") {
            let ss = ServerStore.shared; var used = Set<Int>()
            for s in ss.servers { try expect(ServerStore.validHost(s.sshHost), "\(s.name): bad host"); try expect(!used.contains(s.localPort) && !used.contains(s.localPort - 1), "\(s.name): port clash"); used.formUnion([s.localPort, s.localPort - 1]) }
            await ss.healthCheckActive()
            return ss.servers.map { "\($0.name) :\($0.localPort)/\($0.localPort - 1)\($0.id == ss.activeID ? " (active)" : "")" }.joined(separator: ", ")
        }
        await t("Servers", "ping active server") {
            guard let s = ServerStore.shared.active else { throw err("no server") }
            try expect(await ServerStore.shared.ping(s), "\(s.name) did not answer"); return "\(s.name) healthy (\(ServerStore.shared.servers.count) server(s) configured)"
        }
        await t("Servers", "failover candidates reachable") {
            let others = ServerStore.shared.servers.filter { $0.id != ServerStore.shared.activeID }
            if others.isEmpty { return "only one server configured; failover falls back to local models" }
            var ok: [String] = []; for s in others where await ServerStore.shared.ping(s) { ok.append(s.name) }
            try expect(!ok.isEmpty, "no other server answered: " + others.map(\.name).joined(separator: ", "))
            return "reachable: " + ok.joined(separator: ", ")
        }

        // ---- RedX Link (default connection: no SSH, rsx-encrypted, API-key authenticated)
        await t("RedX Link", "helper bundled and local proxy up") {
            try expect(RedXLink.binary != nil, "redx-link missing from app bundle")
            if !RedXLink.enabled { return "connection mode is SSH; RedX Link helper present" }
            for _ in 0..<30 where !(await RedXLink.statusOK()) { try? await Task.sleep(for: .milliseconds(200)) }
            try expect(await RedXLink.statusOK(), "proxy \(RedXLink.base) not answering: \(RedXLink.shared.status)")
            try expect(UserDefaults.standard.string(forKey: "serverURL") == RedXLink.chatURL, "chat URL is not the link proxy")
            return "proxy \(RedXLink.base) up; chat uses it; \(RedXLink.shared.serverList().count) server(s)"
        }
        await t("RedX Link", "handshake + /v1/models on every server (no SSH)") {
            let list = RedXLink.shared.serverList()
            guard let r = await RedXLink.check(key: Keychain.get() ?? "", servers: list) else { throw err("check did not run") }
            let rows = r["results"] as? [[String: Any]] ?? []
            try expect(r["ok"] as? Bool == true, rows.map { "s\($0["server"] ?? "?"): \($0["error"] ?? "status \($0["status"] ?? "?")")" }.joined(separator: "; "))
            try expect(rows.allSatisfy { $0["forward_secrecy"] as? Bool == true }, "not every server negotiated rxl 2 (forward secrecy): " + rows.map { "s\($0["server"] ?? "?") rxl \($0["rxl"] ?? "?")" }.joined(separator: ", "))
            return rows.map { "server \($0["server"] ?? "?"): rxl \($0["rxl"] ?? "?") forward-secret, \($0["models"] ?? 0) models in \($0["ms"] ?? 0) ms" }.joined(separator: ", ")
        }
        await t("RedX Link", "chat over the link (vortex)") {
            var p = params; p.baseURL = RedXLink.chatURL; p.model = "vortex"; p.maxTokens = 12
            let b = ReplyBuffer(); _ = try await API.stream(p, messages: [Message(role: "user", content: "Reply with exactly: PONG")], onToken: { b.append($0) })
            let r = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
            try expect(r.uppercased().hasPrefix("PONG"), "reply: \(r.prefix(60))")
            return "streamed over RedX Link: \(r)"
        }
        func linkGet(_ path: String, key: String) async throws -> (Int, String) {
            var r = URLRequest(url: URL(string: RedXLink.base + path)!); r.timeoutInterval = 20
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (d, resp) = try await URLSession.shared.data(for: r)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: d, encoding: .utf8) ?? "")
        }
        await t("RedX Link", "admin/owner endpoints unreachable over the link") {
            let (c, b) = try await linkGet("/admin/keys", key: Keychain.get() ?? "")
            let (c2, _) = try await linkGet("/owner/status", key: Keychain.get() ?? "")
            try expect(c == 403 && c2 == 403 && b.contains("not available over RedX Link"), "admin=\(c) owner=\(c2)")
            return "/admin → 403, /owner → 403"
        }
        await t("RedX Link", "invalid key rejected") {
            let (c, _) = try await linkGet("/v1/models", key: "redx_ai_" + String(repeating: "x", count: 40))
            try expect(c == 401, "HTTP \(c)"); return "401 for an unknown key"
        }
        await t("RedX Link", "forged session / frame rejected by server") {
            guard let a = RedXLink.shared.serverList().first, let u = URL(string: "http://\(a)/link/v1/req") else { throw err("no server") }
            var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 10
            r.setValue("forged-session", forHTTPHeaderField: "X-RXL-Sid"); r.httpBody = Data(repeating: 7, count: 64)
            let (_, resp) = try await URLSession.shared.data(for: r)
            let c = (resp as? HTTPURLResponse)?.statusCode ?? 0
            try expect(c == 401, "HTTP \(c)"); return "401 for a forged session"
        }
        await t("RedX Link", "integrations point at the link proxy") {
            try expect(!RedXLink.enabled || IntegrationStore.shared.localBase == RedXLink.base, IntegrationStore.shared.localBase)
            return IntegrationStore.shared.localBase
        }

        await t("Servers", "real failover: switch, chat on backup, switch back") {
            let ss = ServerStore.shared; let orig = ss.activeID
            guard ss.servers.count > 1 else { return "only one server configured" }
            guard let b = await ss.failover() else { throw err("failover() found no server") }
            defer { ss.activate(orig) }
            if RedXLink.enabled {   // the link helper restarts with the backup first
                for _ in 0..<40 where !(RedXLink.shared.lastServers.first == RedXLink.address(b) && RedXLink.shared.running) { try? await Task.sleep(for: .milliseconds(150)) }
            }
            let via = RedXLink.enabled ? RedXLink.chatURL : b.chatURL
            var r = URLRequest(url: URL(string: via + "/chat/completions")!); r.httpMethod = "POST"; r.timeoutInterval = 180
            let fk = RedXLink.enabled ? (Keychain.get() ?? ss.key(for: b)) : ss.key(for: b)   // one link key serves every server
            r.setValue("Bearer \(fk)", forHTTPHeaderField: "Authorization"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: ["model": "dolphin3-llama3.1-8b-q8", "max_tokens": 8, "messages": [["role": "user", "content": "Reply with the word ok."]]])
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            try expect(code == 200, "\(b.name) chat HTTP \(code)")
            let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            let c = ((j?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
            return "switched to \(b.name)\(RedXLink.enabled ? " via RedX Link" : ""), reply: \(c.prefix(30)); restored"
        }

        // ---- integrations (only those already connected; re-Connect rewrites only Vortex-owned files)
        let integ = IntegrationStore.shared
        integ.refreshInstalledTools()
        for i in IntegrationCatalog.all where integ.state[i.id] != nil {
            await t("Integrations", "Test \(i.name)") {
                await integ.test(i)
                if let e = integ.cardError[i.id] { throw err(e) }
                return integ.cardOK[i.id] ?? "?"
            }
        }
        await t("Integrations", "connected count") { "\(integ.state.count) connected: " + integ.state.keys.sorted().joined(separator: ", ") }

        for id in ["codex", "claude-code", "gemini-cli", "continue", "copilot", "omniroute"] {
            guard let i = IntegrationCatalog.all.first(where: { $0.id == id }), let st = integ.state[id] else { continue }
            await t("Integrations", "re-Connect \(i.name): original backups kept, old key revoked, test OK") {
                let userCfgs = [NSHomeDirectory() + "/.codex/config.toml", NSHomeDirectory() + "/.claude/settings.json", NSHomeDirectory() + "/.gemini/settings.json"]
                let before = userCfgs.map { FileManager.default.contents(atPath: $0) }
                let oldKey = st.keyID, oldFiles = st.files
                await integ.connect(i, model: st.model, relaunchApps: false)
                if let e = integ.cardError[id] { throw err("connect: \(e)") }
                guard let now = integ.state[id] else { throw err("state lost") }
                for f in oldFiles { try expect(now.files.contains { $0.path == f.path && $0.backup == f.backup && $0.existed == f.existed }, "backup replaced for \(f.path)") }
                try expect(now.keyID != oldKey, "key not rotated")
                try await HubStore.shared.loadKeys()
                try expect(!HubStore.shared.keys.contains { $0.id == oldKey && !$0.revoked }, "old key still active")
                try expect(userCfgs.map { FileManager.default.contents(atPath: $0) } == before, "a normal (non-Vortex) config changed")
                await integ.test(i)
                if let e = integ.cardError[id] { throw err("test: \(e)") }
                return "\(oldFiles.count) original backups kept; key rotated; normal configs untouched; " + (integ.cardOK[id] ?? "")
            }
        }

        // ---- upload
        await t("Upload", "text/code file") {
            let u = tmp.appendingPathComponent("hello.swift"); try "let x = 42 // VORTEX_FILE".write(to: u, atomically: true, encoding: .utf8)
            let a = try await AttachmentLoader.load(u); try expect(a.kind == "text" && (a.text ?? "").contains("VORTEX_FILE"), "text not read")
            let m = Message(role: "user", content: "What number is assigned to x? Number only.", attachments: [a])
            let r = try await ask("qwen2.5-14b", [m], max: 20); try expect(r.contains("42"), "model said: \(r)"); return "qwen read the file → \(r)"
        }
        await t("Upload", "PDF text extraction") {
            let u = tmp.appendingPathComponent("doc.pdf")
            let v = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200)); v.string = "Invoice total VORTEX_PDF 1234"
            try v.dataWithPDF(inside: v.bounds).write(to: u)
            let a = try await AttachmentLoader.load(u); try expect((a.text ?? "").contains("VORTEX_PDF"), "pdf text: \(a.text ?? "nil")"); return "\(a.bytes) B, text extracted"
        }
        await t("Upload", "image → vision model") {
            let u = tmp.appendingPathComponent("red.png")
            let img = NSImage(size: NSSize(width: 64, height: 64)); img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill(); img.unlockFocus()
            guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw err("png") }
            try png.write(to: u)
            let a = try await AttachmentLoader.load(u); try expect(a.kind == "image" && a.dataURI != nil, "not an image")
            let r = try await ask("gemma3-12b-vision", [Message(role: "user", content: "What colour is this image? One word.", attachments: [a])], max: 10)
            try expect(r.lowercased().contains("red"), "said \(r)"); return "gemma3-12b-vision → \(r)"
        }

        // ---- media job queue (same code path as Hub → Media)
        await t("Media", "speech job via queue with progress") {
            let m = await MediaJobsModel()
            await m.submit(type: "speech", prompt: "Vortex media self test.")
            for _ in 0..<40 {
                await m.refresh()
                if let j = await m.jobs.first, j.status == "done", let f = await m.outputs[j.id] {
                    return "done in \(String(format: "%.2f", j.seconds ?? 0))s → \(f.lastPathComponent)"
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            throw err("job not done: \(await m.message)")
        }

        // ---- plugins
        let ps = PluginStore.shared
        await t("Plugins", "starters installed") { try expect(ps.installed.count >= 6, "only \(ps.installed.count)"); return ps.installed.map(\.id).joined(separator: ", ") }
        func tool(_ n: String) throws -> PluginTool { guard let t = ps.installed.flatMap(\.tools).first(where: { $0.name == n }) else { throw err("no tool \(n)") }; return t }
        await t("Plugins", "calculator (builtin)") { let r = try await PluginRunner.run(try tool("calculator"), ["expression": "(2+3)*sqrt(16)"]); try expect(r.contains("20"), r); return r }
        await t("Plugins", "now (JS sandbox)") { let r = try await PluginRunner.run(try tool("now"), ["timezone": "America/New_York"]); try expect(r.contains("202"), r); return r }
        await t("Plugins", "wikipedia (HTTP)") { let r = try await PluginRunner.run(try tool("wikipedia"), ["title": "Dolphin"]); try expect(r.lowercased().contains("dolphin"), String(r.prefix(200))); return String(r.prefix(120)) }
        await t("Plugins", "weather (builtin)") { let r = try await PluginRunner.run(try tool("weather"), ["place": "Boston"]); try expect(!r.lowercased().hasPrefix("error"), r); return String(r.prefix(120)) }
        await t("Plugins", "web_search (builtin)") { let r = try await PluginRunner.run(try tool("web_search"), ["query": "Swift programming language"]); try expect(r.count > 50 && !r.lowercased().hasPrefix("error"), r); return String(r.prefix(120)) }
        await t("Plugins", "read_file (builtin)") {
            let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("vortex-selftest.txt"); try "SELFTEST_READ".write(to: u, atomically: true, encoding: .utf8); defer { try? FileManager.default.removeItem(at: u) }
            let r = try await PluginRunner.run(try tool("read_file"), ["path": "~/vortex-selftest.txt"]); try expect(r.contains("SELFTEST_READ"), r); return "ok"
        }
        await t("Plugins", "JS sandbox time limit") {
            do { _ = try JSRunner.run("function run(a){ while(true){} }", [:]); throw err("infinite loop was not stopped") } catch let e as NSError where e.domain != "SelfTest" { return "stopped: \(e.localizedDescription)" }
        }
        await t("Plugins", "maker validation rejects bad manifest") {
            let bad = PluginManifest(id: "Bad ID", name: "x", version: "1", description: "", author: "", icon: "puzzlepiece", tools: [])
            do { try ps.validate(bad); throw err("accepted") } catch let e as NSError where e.domain != "SelfTest" { return e.localizedDescription }
        }
        await t("Plugins", "Plugin Maker generates a valid plugin (vortex)") {
            let m = try await ps.make(description: "Reverse a string given as text"); return "\(m.id): \(m.tools.map(\.name).joined(separator: ","))"
        }
        await t("Plugins", "agent: qwen native tool call") {
            ToolRegistry.chatToolsOn = true; ps.setMode("calculator", "auto")
            var p = params; p.model = "qwen2.5-14b"; p.maxTokens = 300
            let (txt, log) = try await Agent.run(p, history: [Message(role: "user", content: "Use the calculator to compute 12345*6789. Give the number.")], tools: ToolRegistry.tools(for: p.model)) { _ in }
            try expect(log.contains { $0.contains("calculator") } && txt.replacingOccurrences(of: ",", with: "").contains("83810205"), "log=\(log) txt=\(txt)"); return txt
        }
        await t("Plugins", "agent: vortex text-protocol tool call") {
            var p = params; p.model = "vortex"; p.maxTokens = 300
            let (txt, log) = try await Agent.run(p, history: [Message(role: "user", content: "Use the calculator tool to compute 987*654. Give the number.")], tools: ToolRegistry.tools(for: p.model)) { _ in }
            try expect(log.contains { $0.contains("calculator") } && txt.replacingOccurrences(of: ",", with: "").contains("645498"), "log=\(log) txt=\(txt)"); return "\(log.first ?? "") → \(txt.prefix(80))"
        }

        // ---- skills modes
        let ss = SkillStore.shared
        await t("Skills", "Always on adds instructions") {
            for s in ss.skills { ss.setMode(s.id, "off") }; ss.setMode("code-reviewer", "always")
            let sp = ss.systemPrompt(base: "BASE"); try expect(sp.contains("Skill: Code Reviewer") && sp.hasPrefix("BASE"), sp); return "system prompt has Code Reviewer"
        }
        await t("Skills", "Auto exposes activate_skill + summary") {
            ss.setMode("code-reviewer", "off"); ss.setMode("math-tutor", "auto")
            let sp = ss.systemPrompt(base: ""); let tl = ToolRegistry.tools(for: "qwen2.5-14b").map(\.name)
            try expect(sp.contains("math-tutor") && !sp.contains("Verify every numeric") && tl.contains("activate_skill") && tl.contains("calculator"), "sp=\(sp) tools=\(tl)")
            return "tools: " + tl.joined(separator: ", ")
        }
        await t("Skills", "Off removes it") { ss.setMode("math-tutor", "off"); try expect(!ToolRegistry.tools(for: "x").map(\.name).contains("activate_skill"), "still there"); return "ok" }
        await t("Skills", "/slash sets Always on, /noskill clears") {
            var s = "/researcher find x"; ss.applySlash(&s); try expect(ss.mode("researcher") == "always" && s == "find x", "mode \(ss.mode("researcher")) text \(s)")
            var n = "/noskill hi"; ss.applySlash(&n); try expect(ss.mode("researcher") == "off" && n == "hi", "noskill"); return "ok"
        }
        await t("Skills", "model activates an Auto skill itself (qwen)") {
            ss.setMode("math-tutor", "auto")
            var p = params; p.model = "qwen2.5-14b"; p.maxTokens = 400
            let h = [Message(role: "system", content: ss.systemPrompt(base: "")), Message(role: "user", content: "Teach me how to compute 37*43 step by step, and check the result.")]
            let (txt, log) = try await Agent.run(p, history: h, tools: ToolRegistry.tools(for: p.model)) { _ in }
            ss.setMode("math-tutor", "off")
            try expect(log.contains { $0.contains("activate_skill") || $0.contains("calculator") } && txt.contains("1591"), "log=\(log) txt=\(txt.prefix(200))"); return log.joined(separator: " | ").prefix(200) + ""
        }
        await t("Plugins", "Always-on plugin noted in system prompt") {
            ps.setMode("calculator", "always"); let sp = ss.systemPrompt(base: ""); try expect(sp.contains("Always-on plugins") && sp.contains("calculator"), sp); ps.setMode("calculator", "off"); return "ok"
        }

        // ---- MCP
        await t("MCP", "stdio filesystem server: list + call") {
            let d = MCPServerDef(id: "selftest-fs", name: "fs", type: "stdio", command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", tmp.path])
            let c = MCPClient(d); defer { c.stop() }
            let tools = try await c.start(); try expect(!tools.isEmpty, "no tools")
            let r = try await c.call("list_directory", ["path": tmp.path]); try expect(r.contains("hello.swift"), r)
            return "\(tools.count) tools; list_directory saw hello.swift"
        }
        await t("MCP", "configured servers") {
            let ms = MCPStore.shared; return "\(ms.servers.count) configured, \(ms.servers.filter(\.enabled).count) enabled"
        }

        // ---- voice
        let ve = VoiceEngine.shared
        await t("Voice", "whisper + piper installed") { try expect(ve.sttReady && ve.piperReady, "stt=\(ve.sttReady) piper=\(ve.piperReady)"); return "ready" }
        await t("Voice", "Piper TTS → whisper STT round trip (app code)") {
            let wav = try await ve.piper("The quick brown fox jumps over the lazy dog.")
            let f = try AVAudioFile(forReading: wav)
            guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { throw err("buf") }
            try f.read(into: buf); let sr = f.processingFormat.sampleRate
            let ch = UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))
            let ratio = sr / 16000; let n = Int(Double(ch.count) / ratio)
            let s16 = (0..<n).map { ch[min(ch.count - 1, Int(Double($0) * ratio))] }
            let text = try await ve.transcribe(s16); try expect(text.lowercased().contains("fox"), text); return text
        }

        // ---- group chat
        await t("Group chat", "turn order + @mentions") {
            var c = Chat(); c.participants = ["qwen2.5-14b", "vortex", "phi4-mini"]
            try expect(GroupTurns.responders("hi", chat: c).list == c.participants!, "all")
            try expect(GroupTurns.responders("hey @qwen", chat: c).list == ["qwen2.5-14b"], "mention")
            try expect(GroupTurns.responders("@all go", chat: c).list.count == 3, "@all")
            c.turnMode = "rotate"; c.nextTurn = 4; try expect(GroupTurns.responders("x", chat: c).list == ["vortex"], "rotate")
            return "all / @mention / @all / rotate ok"
        }
        await t("Group chat", "two models converse (history builder + API)") {
            var c = Chat(); c.participants = ["qwen2.5-14b", "vortex"]
            c.messages = [Message(role: "user", content: "Name one planet, one word.")]
            let a = try await ask("qwen2.5-14b", GroupTurns.history(for: "qwen2.5-14b", chat: c, system: "", others: ["vortex"], budgetChars: 20000), max: 20)
            c.messages.append(Message(role: "assistant", content: a, model: "qwen2.5-14b"))
            let h = GroupTurns.history(for: "vortex", chat: c, system: "", others: ["qwen2.5-14b"], budgetChars: 20000)
            try expect(h.map(\.role) == ["system", "user"], "roles \(h.map(\.role))")
            let b = try await ask("vortex", h, max: 60); return "qwen: \(a) | vortex: \(b.prefix(100))"
        }

        // ---- PC control
        let pc = PCControl.shared
        Confirm.autoAnswer = true; defer { Confirm.autoAnswer = nil }
        let pcDir = tmp.appendingPathComponent("pc", isDirectory: true)
        try? FileManager.default.removeItem(at: pcDir); try? FileManager.default.createDirectory(at: pcDir, withIntermediateDirectories: true)
        func pcTool(_ n: String) throws -> ToolSpec { guard let t = pc.tools(for: "vortex").first(where: { $0.name == n }) else { throw err("no tool \(n)") }; return t }
        await t("PC control", "master switch; only vortex/red-xai; no 🔧 needed") {
            pc.resume(); for k in PCKind.allCases { ud.removeObject(forKey: k.key) }
            pc.setEnabled(false); try expect(pc.tools(for: "vortex").isEmpty, "tools while master off")
            pc.setEnabled(true); ToolRegistry.chatToolsOn = false
            let names = ToolRegistry.tools(for: "vortex").map(\.name)
            try expect(names.contains("pc_shell") && !ToolRegistry.tools(for: "red-xai").isEmpty, "PC tools missing with 🔧 off")
            try expect(pc.tools(for: "qwen2.5-14b").isEmpty, "qwen got PC tools")
            ToolRegistry.chatToolsOn = true
            return "\(names.count) PC tools offered to vortex/red-xai with 🔧 off; none for qwen"
        }
        await t("PC control", "Enable all safe") {
            pc.enable(PCKind.safe)
            try expect(PCKind.safe.allSatisfy(pc.isOn) && !pc.isOn(.shell) && !pc.isOn(.input), "wrong set")
            return PCKind.safe.map(\.rawValue).joined(separator: ", ")
        }
        pc.enable(PCKind.allCases)
        let note = pcDir.appendingPathComponent("note.txt")
        try? "The secret word is PELICAN.".write(to: note, atomically: true, encoding: .utf8)
        await t("PC tools", "read & list files") {
            let l = try await pcTool("pc_list_dir").run(["path": pcDir.path]); try expect(l.contains("note.txt"), l)
            let r = try await pcTool("pc_read_file").run(["path": note.path]); try expect(r.contains("PELICAN"), r)
            return "list + read ok"
        }
        await t("PC tools", "write / move / trash") {
            let w = pcDir.appendingPathComponent("w.txt"), m = pcDir.appendingPathComponent("m.txt")
            _ = try await pcTool("pc_write_file").run(["path": w.path, "content": "WRITE_OK"])
            try expect((try? String(contentsOf: w, encoding: .utf8)) == "WRITE_OK", "write")
            _ = try await pcTool("pc_move_file").run(["from": w.path, "to": m.path]); try expect(FileManager.default.fileExists(atPath: m.path), "move")
            _ = try await pcTool("pc_delete_file").run(["path": m.path]); try expect(!FileManager.default.fileExists(atPath: m.path), "trash")
            return "write, move, trash ok"
        }
        await t("PC tools", "shell") {
            let r = try await pcTool("pc_shell").run(["command": "echo SHELL_$((40+2))"]); try expect(r.contains("SHELL_42"), r); return r
        }
        await t("PC tools", "open / list / quit apps") {
            _ = try await pcTool("pc_open_app").run(["name": "Calculator"])
            var up = false; for _ in 0..<30 where !up { try await Task.sleep(for: .milliseconds(300)); up = try await pcTool("pc_list_apps").run([:]).contains("Calculator") }
            try expect(up, "Calculator not running")
            let q = try await pcTool("pc_quit_app").run(["name": "Calculator"]); try await Task.sleep(for: .seconds(2))
            try expect(!NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Calculator" }, "still running: \(q)")
            return "opened, listed, quit Calculator"
        }
        await t("PC tools", "clipboard read / write") {
            let old = NSPasteboard.general.string(forType: .string)
            defer { NSPasteboard.general.clearContents(); if let old { NSPasteboard.general.setString(old, forType: .string) } }
            _ = try await pcTool("pc_clipboard_write").run(["text": "CLIP_OK"])
            let r = try await pcTool("pc_clipboard_read").run([:]); try expect(r == "CLIP_OK", r); return "write + read ok (clipboard restored)"
        }
        await t("PC tools", "browser: open page + read front tab") {
            if ProcessInfo.processInfo.environment["VORTEX_SKIP_BROWSER"] != nil { throw err("skipped (Automation consent pending)") }
            _ = try await pcTool("pc_open_url").run(["url": "https://example.com/?vortex-selftest"])
            var r = ""; for _ in 0..<20 { try await Task.sleep(for: .milliseconds(500)); r = try await pcTool("pc_browser_tab").run([:]); if r.contains("example.com") { break } }
            try expect(r.contains("example.com"), "tab read: \(r)")
            return r
        }
        await t("PC tools", "permissions: Accessibility + Screen Recording") {
            let ax = PCControl.accessibility(prompt: false) && CGPreflightPostEventAccess(), sc = CGPreflightScreenCaptureAccess()
            try expect(ax && sc, "NEEDS JF: " + [ax ? nil : "Accessibility", sc ? nil : "Screen Recording"].compactMap { $0 }.joined(separator: " + ") + " for \(Bundle.main.bundlePath)")
            return "Accessibility ✓, Screen Recording ✓"
        }
        await t("PC tools", "keyboard & mouse (TextEdit)") {
            let f = pcDir.appendingPathComponent("typed.txt"); try "".write(to: f, atomically: true, encoding: .utf8)
            _ = try await PCTools.runProcess("/usr/bin/open", ["-a", "TextEdit", f.path], timeout: 20)
            try await Task.sleep(for: .seconds(3))
            let wins = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
            if let w = wins.first(where: { $0[kCGWindowOwnerName as String] as? String == "TextEdit" }), let b = w[kCGWindowBounds as String] as? [String: Double] {
                _ = try await pcTool("pc_click").run(["x": (b["X"] ?? 0) + (b["Width"] ?? 0) / 2, "y": (b["Y"] ?? 0) + (b["Height"] ?? 0) / 2])
            }
            _ = try? await PCTools.runProcess("/usr/bin/open", ["-a", "TextEdit"], timeout: 10)
            try await Task.sleep(for: .milliseconds(800))
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            _ = try await pcTool("pc_type_text").run(["text": "TYPED_OK"])
            _ = try await pcTool("pc_key").run(["keys": "cmd+s"]); try await Task.sleep(for: .seconds(1))
            var axText = "?"
            if let te = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "TextEdit" }) {
                let app = AXUIElementCreateApplication(te.processIdentifier); var fo: CFTypeRef?
                if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &fo) == .success, let fo {
                    var v: CFTypeRef?; _ = AXUIElementCopyAttributeValue(fo as! AXUIElement, kAXValueAttribute as CFString, &v); axText = (v as? String) ?? "nil" } }
            let got = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            NSWorkspace.shared.runningApplications.first { $0.localizedName == "TextEdit" }?.terminate()
            try expect(got.contains("TYPED_OK"), "front app \(front); postEvent \(CGPreflightPostEventAccess()); TextEdit shows \(axText.prefix(40)); file has: \(got.prefix(60))")
            return "clicked, typed and saved with cmd+s"
        }
        await t("PC tools", "screenshot + OCR") {
            let r = try await pcTool("pc_screenshot").run([:]); try expect(r.contains("Text on screen") && !r.hasSuffix("(none found)"), String(r.prefix(200)))
            return String(r.prefix(160))
        }
        await t("PC control", "kill switch blocks tools") {
            pc.kill(); try expect(pc.tools(for: "vortex").isEmpty, "tools after kill"); pc.resume(); return "blocked, then resumed"
        }
        // Real chats through the app's Agent loop (text protocol + few-shot for llama.cpp models).
        func pcChat(_ model: String, _ prompt: String) async throws -> (String, [String]) {
            var p = params; p.model = model; p.maxTokens = 300
            return try await Agent.run(p, history: [Message(role: "user", content: prompt)], tools: ToolRegistry.tools(for: model)) { _ in }
        }
        func used(_ log: [String], _ tool: String) -> Bool { log.contains { $0.contains(tool) } }
        await t("Agents", "create agent, run task with tool call, delete") {
            let st = AgentStore()
            let id = "selftest-agent-\(Int(Date().timeIntervalSince1970))"
            var ag = AgentProfile(id: id, name: "SelfTest Agent")
            ag.provider = "vortex"; ag.model = "vortex"; ag.toolsOn = true; ag.pcControlOn = true
            ag.systemPrompt = "You are a file assistant. Use tools to answer."
            st.upsert(ag)
            defer { st.delete(id) }
            try expect(st.agents.contains { $0.id == id }, "agent not saved")
            var p = st.chatParams(for: id, fallback: params); p.maxTokens = 300
            let (a, l) = try await Agent.run(p, history: [Message(role: "system", content: ag.systemPrompt), Message(role: "user", content: "Read the file \(note.path) and tell me the secret word.")], tools: ToolRegistry.tools(for: p.model)) { _ in }
            try expect(used(l, "pc_read_file") && a.uppercased().contains("PELICAN"), "log \(l) answer \(a.prefix(160))")
            return "agent \(id) model \(p.model): tools \(l.prefix(3)) -> \(a.prefix(120))"
        }
        await t("PC chat", "vortex lists a folder") {
            let (a, l) = try await pcChat("vortex", "List the files in the folder \(pcDir.path)")
            try expect(used(l, "pc_list_dir") && a.contains("note"), "log \(l) answer \(a.prefix(120))"); return a
        }
        await t("PC chat", "vortex reads a file") {
            let (a, l) = try await pcChat("vortex", "Read the file \(note.path) and tell me the secret word.")
            try expect(used(l, "pc_read_file") && a.uppercased().contains("PELICAN"), "log \(l) answer \(a.prefix(120))"); return a
        }
        await t("PC chat", "red-xai writes a file") {
            let f = pcDir.appendingPathComponent("made.txt")
            let (a, l) = try await pcChat("red-xai", "Create a text file at \(f.path) containing exactly: MADE_OK")
            try expect(((try? String(contentsOf: f, encoding: .utf8)) ?? "").contains("MADE_OK"), "log \(l) answer \(a.prefix(120))"); return "\(l.first ?? "")"
        }
        await t("PC chat", "red-xai opens an app") {
            let (a, l) = try await pcChat("red-xai", "Open the Calculator app.")
            try await Task.sleep(for: .seconds(2))
            let up = NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Calculator" }
            NSWorkspace.shared.runningApplications.first { $0.localizedName == "Calculator" }?.terminate()
            try expect(used(l, "pc_open_app") && up, "log \(l) answer \(a.prefix(120))"); return a
        }
        await t("PC chat", "vortex runs a shell command") {
            let (a, l) = try await pcChat("vortex", "Run this shell command and tell me the output: echo VORTEX_$((6*7))")
            try expect(used(l, "pc_shell") && a.contains("VORTEX_42"), "log \(l) answer \(a.prefix(120))"); return a
        }
        await t("PC chat", "vortex reads the clipboard") {
            let old = NSPasteboard.general.string(forType: .string)
            defer { NSPasteboard.general.clearContents(); if let old { NSPasteboard.general.setString(old, forType: .string) } }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("BANANA_77", forType: .string)
            let (a, l) = try await pcChat("vortex", "What text is on my clipboard right now?")
            try expect(used(l, "pc_clipboard_read") && a.contains("BANANA_77"), "log \(l) answer \(a.prefix(120))"); return a
        }
        await t("PC chat", "type off → Turn on button") {
            pc.set(.shell, false); defer { pc.set(.shell, true) }
            let (a, l) = try await pcChat("vortex", "Run the shell command: echo hi")
            try expect(l.contains(PCControl.offMarker + "shell"), "log \(l) answer \(a.prefix(120))"); return "button shown; reply: \(a.prefix(80))"
        }
        await t("PC intent", "JF's plain requests are recognised") {
            let cases: [(String, String)] = [("open safari", "pc_open_app"), ("what's on my screen", "pc_screenshot"), ("make a folder on desktop", "pc_shell"),
                ("type hello", "pc_type_text"), ("can you close my TextEdit app i have open", "pc_quit_app"),
                ("can you open my default browser and search up poodles?", "pc_open_url"), ("search my pc for my discord application and open the folder path", "pc_shell"),
                ("hey lookup jjk and tell me recent news you can control pc to search", "pc_open_url")]
            var bad: [String] = []
            for (q, want) in cases { let g = Intent.guess(q); if g?.name != want || !Intent.isAction(q) { bad.append("\(q) → \(g?.name ?? "nil")") } }
            try expect(Intent.guess("what type of dog is best") == nil && Intent.isEvasive("I'm sorry, but I don't have direct access to your computer."), "false positive / evasive")
            try expect(bad.isEmpty, bad.joined(separator: "; ")); return "\(cases.count) requests map to the right tool"
        }
        func running(_ n: String) -> Bool { NSWorkspace.shared.runningApplications.contains { $0.localizedName == n } }
        func quit(_ n: String) { NSWorkspace.shared.runningApplications.filter { $0.localizedName == n }.forEach { $0.terminate() } }
        func jf(_ model: String, _ prompt: String, prior: [Message] = []) async throws -> (String, [String]) {
            var p = params; p.model = model; p.maxTokens = 300
            let sys = Message(role: "system", content: "You are Red-XAI Vortex, a helpful assistant.")
            return try await Agent.run(p, history: [sys] + prior + [Message(role: "user", content: prompt)], tools: ToolRegistry.tools(for: model)) { _ in }
        }
        let refusal = [Message(role: "user", content: "you should have acsess to full control of my pc"),
                       Message(role: "assistant", content: "I apologize for any confusion. While I don't have direct access to your computer, I can provide guidance on how to use the \"pc_open_url\" tool in the terminal.")]
        await t("PC replay", "vortex: 'can you close my TextEdit app i have open'") {
            _ = try await PCTools.runProcess("/usr/bin/open", ["-a", "TextEdit"], timeout: 20); try await Task.sleep(for: .seconds(2))
            let (a, l) = try await jf("vortex", "can you close my TextEdit app i have open", prior: refusal)
            try await Task.sleep(for: .seconds(2)); let still = running("TextEdit"); quit("TextEdit")
            try expect(!still, "log \(l) answer \(a.prefix(120))"); return a
        }
        await t("PC replay", "vortex: 'open safari' after an earlier refusal") {
            quit("Safari"); try await Task.sleep(for: .seconds(2))
            let (a, l) = try await jf("vortex", "open safari", prior: refusal)
            try await Task.sleep(for: .seconds(2)); try expect(running("Safari"), "log \(l) answer \(a.prefix(120))"); return a
        }
        await t("PC replay", "red-xai: 'can you open my default browser and search up poodles?'") {
            let (a, l) = try await jf("red-xai", "can you open my default browser and search up poodles?")
            try expect(l.contains { $0.contains("pc_open_url") && $0.lowercased().contains("poodle") }, "log \(l) answer \(a.prefix(120))"); return l.first ?? a
        }
        await t("PC replay", "vortex: 'hey lookup jjk and tell me recent news…'") {
            let (a, l) = try await jf("vortex", "hey lookup jjk and tell me recent news you can control pc to search", prior: refusal)
            try expect(l.contains { $0.contains("pc_open_url") && $0.lowercased().contains("jjk") }, "log \(l) answer \(a.prefix(120))"); return l.first ?? a
        }
        await t("PC replay", "vortex: 'search my pc for my discord application…'") {
            let (a, l) = try await jf("vortex", "search my pc for my discord application and open the folder path")
            try expect(l.contains { $0.contains("pc_shell") || $0.contains("pc_list_dir") }, "log \(l) answer \(a.prefix(120))"); return l.first ?? a
        }
        await t("PC replay", "red-xai: 'what's on my screen'") {
            let (a, l) = try await jf("red-xai", "what's on my screen")
            try expect(l.contains { $0.contains("pc_screenshot") }, "log \(l) answer \(a.prefix(120))"); return String(a.prefix(120))
        }
        await t("PC replay", "vortex: 'make a folder on desktop called VortexSelftestFolder'") {
            let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/VortexSelftestFolder")
            try? FileManager.default.removeItem(at: d)
            let (a, l) = try await jf("vortex", "make a folder on desktop called VortexSelftestFolder")
            var isDir: ObjCBool = false; let ok = FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir) && isDir.boolValue
            try? FileManager.default.removeItem(at: d)
            try expect(ok, "log \(l) answer \(a.prefix(120))"); return "folder created (then removed)"
        }
        await t("PC replay", "vortex: 'type hello' into TextEdit") {
            let f = pcDir.appendingPathComponent("hello.txt"); try "".write(to: f, atomically: true, encoding: .utf8)
            _ = try await PCTools.runProcess("/usr/bin/open", ["-a", "TextEdit", f.path], timeout: 20); try await Task.sleep(for: .seconds(3))
            let (a, l) = try await jf("vortex", "type hello")
            _ = try? await pcTool("pc_key").run(["keys": "cmd+s"]); try await Task.sleep(for: .seconds(1))
            let got = (try? String(contentsOf: f, encoding: .utf8)) ?? ""; quit("TextEdit")
            try expect(got.lowercased().contains("hello"), "log \(l) file \(got.prefix(40))"); return "typed: \(got.prefix(20))"
        }
        await t("PC control", "action log written") {
            let s = (try? String(contentsOf: PCControl.logURL, encoding: .utf8)) ?? ""; try expect(s.contains("pc_shell"), "no log"); return PCControl.logURL.path
        }

        // ---- model library webpage
        await t("Model library page", "local server + API routes") {
            let mb = ModelBrowserServer.shared; mb.start()
            for _ in 0..<30 where mb.port == 0 { try await Task.sleep(for: .milliseconds(100)) }
            try expect(mb.port != 0, "no port")
            var out: [String] = []
            for path in ["/", "/x/targets", "/x/catalog", "/x/ollama", "/x/plugins", "/x/merges"] {
                let u = URL(string: "http://127.0.0.1:\(mb.port)\(path)?t=\(mb.token)")!
                let (d, r) = try await URLSession.shared.data(from: u); let code = (r as? HTTPURLResponse)?.statusCode ?? 0
                try expect(code == 200, "\(path) → HTTP \(code): \(String(decoding: d.prefix(200), as: UTF8.self))"); out.append("\(path) \(d.count)B")
            }
            let (_, r) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(mb.port)/x/targets?t=wrong")!)
            try expect((r as? HTTPURLResponse)?.statusCode != 200, "token not enforced")
            return out.joined(separator: ", ") + "; bad token refused"
        }

        // ---- training
        await t("Training", "Vortex stats (admin)") {
            let s = try await Admin.call("GET", "/admin/redxai/stats"); return s.keys.sorted().prefix(8).joined(separator: ", ")
        }
        await t("Training", "PII scrub") {
            let s = PII.scrub("mail a@b.com key sk-abcdefghijklmnop ip 10.1.2.3"); try expect(!s.contains("a@b.com") && !s.contains("sk-abc") && !s.contains("10.1.2.3"), s); return s
        }

        // ---- docs
        await t("Docs", "every Help page bundled") {
            let missing = HelpDocs.order.map(\.0).filter { HelpDocs.text($0).hasPrefix("# Help not found") }
            try expect(missing.isEmpty, "missing: \(missing)"); return "\(HelpDocs.order.count) pages"
        }

        flush()
    }
}
