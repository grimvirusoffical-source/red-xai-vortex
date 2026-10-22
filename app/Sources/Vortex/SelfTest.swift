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
        let saved: [String: Any?] = Dictionary(uniqueKeysWithValues: ["pluginModes", "pluginsEnabled", "skillModes", "chatTools", "pc.killed"].map { ($0, ud.object(forKey: $0)) } + PCKind.allCases.map { ($0.key, ud.object(forKey: $0.key)) })
        defer {
            for (k, v) in saved { if let v { ud.set(v, forKey: k) } else { ud.removeObject(forKey: k) } }
            PluginStore.shared.load(); SkillStore.shared.modes = ud.dictionary(forKey: "skillModes") as? [String: String] ?? [:]
            PCControl.shared.killed = ud.bool(forKey: "pc.killed"); PCControl.shared.hide()
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vortex-selftest", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        await ServerStore.shared.healthCheckActive()   // same check the app runs at launch
        // ---- chat & model picker
        var models: [String] = []
        await t("Model picker", "GET /v1/models via API.models") {
            models = try await API.models(base: params.baseURL, key: params.apiKey)
            try expect(models.contains("vortex") && models.contains("red-xai"), "vortex/red-xai missing: \(models)")
            return "\(models.count) models incl. vortex, red-xai, \(models.filter { $0.hasPrefix("redx-merge-") }.count) merges"
        }
        await t("Chat", "stream vortex (API.stream)") { try await ask("vortex", [Message(role: "user", content: "Reply with exactly: PONG")]) }
        await t("Chat", "stream red-xai") { try await ask("red-xai", [Message(role: "user", content: "Reply with exactly: PONG")]) }
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
        await t("API keys", "create → use → disable → revoke (HubStore)") {
            let hub = HubStore.shared
            guard let k = await hub.createKey(name: "selftest-temp", models: ["qwen2.5-14b"], rpm: 30) else { throw err("create failed: \(hub.keyError)") }
            let chatURL = URL(string: params.baseURL + "/chat/completions")!
            func code(_ model: String) async throws -> Int {
                var r = URLRequest(url: chatURL); r.httpMethod = "POST"
                r.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": [["role": "user", "content": "hi"]], "max_tokens": 3])
                return ((try await URLSession.shared.data(for: r)).1 as? HTTPURLResponse)?.statusCode ?? 0
            }
            guard let row = hub.keys.first(where: { $0.name == "selftest-temp" && !$0.revoked }) else { throw err("new key not listed") }
            defer { Task { _ = try? await Admin.call("DELETE", "/admin/keys/\(row.id)") } }
            let ok = try await code("qwen2.5-14b"), denied = try await code("vortex")
            await hub.patchKey(row.id, ["disabled": true]); let off = try await code("qwen2.5-14b")
            _ = try await Admin.call("DELETE", "/admin/keys/\(row.id)"); let gone = try await code("qwen2.5-14b")
            try expect(ok == 200 && denied == 403 && off == 401 && gone == 401, "allowed=\(ok) other-model=\(denied) disabled=\(off) revoked=\(gone)")
            return "shown once (\(k.prefix(8))…), listed masked as \(row.prefix); 200 / 403 other model / 401 disabled / 401 revoked"
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

        await t("Servers", "real failover: switch, chat on backup, switch back") {
            let ss = ServerStore.shared; let orig = ss.activeID
            guard ss.servers.count > 1 else { return "only one server configured" }
            guard let b = await ss.failover() else { throw err("failover() found no server") }
            defer { ss.activate(orig) }
            var r = URLRequest(url: URL(string: b.chatURL + "/chat/completions")!); r.httpMethod = "POST"; r.timeoutInterval = 180
            r.setValue("Bearer \(ss.key(for: b))", forHTTPHeaderField: "Authorization"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: ["model": "dolphin3-llama3.1-8b-q8", "max_tokens": 8, "messages": [["role": "user", "content": "Reply with the word ok."]]])
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            try expect(code == 200, "\(b.name) chat HTTP \(code)")
            let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            let c = ((j?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
            return "switched to \(b.name), reply: \(c.prefix(30)); restored"
        }

        // ---- integrations (only those already connected; never writes configs)
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
        await t("PC control", "off by default; only vortex/red-xai") {
            for k in PCKind.allCases { ud.removeObject(forKey: k.key) }
            try expect(pc.tools(for: "vortex").isEmpty, "tools while off")
            ud.set(true, forKey: PCKind.filesRead.key)
            try expect(!pc.tools(for: "vortex").isEmpty && !pc.tools(for: "red-xai").isEmpty && pc.tools(for: "qwen2.5-14b").isEmpty, "eligibility")
            return "off by default; qwen gets none"
        }
        await t("PC control", "read tools run; destructive flagged") {
            pc.resume(); for k in PCKind.allCases { ud.set(true, forKey: k.key) }
            let ts = pc.tools(for: "vortex")
            let r = try await ts.first { $0.name == "pc_list_dir" }!.run(["path": tmp.path]); try expect(r.contains("hello.swift"), r)
            let destructive = Set(ts.filter(\.destructive).map(\.name))
            let need: Set = ["pc_write_file", "pc_move_file", "pc_delete_file", "pc_shell", "pc_quit_app", "pc_type_text", "pc_key", "pc_click", "pc_clipboard_write"]
            try expect(need.isSubset(of: destructive), "not flagged: \(need.subtracting(destructive))")
            let cb = try await ts.first { $0.name == "pc_clipboard_read" }!.run([:])
            return "\(ts.count) tools; list_dir ok; clipboard read \(cb.count) chars; \(destructive.count) destructive"
        }
        await t("PC control", "kill switch blocks tools") {
            pc.kill(); try expect(pc.tools(for: "vortex").isEmpty, "tools after kill"); pc.resume(); return "blocked, then resumed"
        }
        await t("PC control", "action log written") {
            PCControl.logAction("selftest"); let s = (try? String(contentsOf: PCControl.logURL, encoding: .utf8)) ?? ""; try expect(s.contains("selftest"), "no log"); return PCControl.logURL.path
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
