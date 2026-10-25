import Foundation
import AppKit

/// One callable tool exposed to a model (from a plugin, an MCP server or PC control).
struct ToolSpec {
    var name: String
    var description: String
    var schema: [String: Any]          // JSON Schema for arguments
    var source: String                 // "plugin:<id>" | "mcp:<server>" | "pc:<kind>"
    var destructive = false            // always asks before running
    var run: ([String: Any]) async throws -> String
}

/// Collects the tools that are switched on for a chat/model.
@MainActor enum ToolRegistry {
    static var chatToolsOn: Bool {
        get { UserDefaults.standard.object(forKey: "chatTools") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "chatTools") }
    }
    static func tools(for model: String) -> [ToolSpec] {
        var t: [ToolSpec] = []
        if chatToolsOn { t += PluginStore.shared.enabledTools(); t += MCPStore.shared.enabledTools() }
        t += PCControl.shared.tools(for: model)   // PC tools follow the PC Control master switch, not 🔧
        if chatToolsOn { t += SkillStore.shared.activeExtraTools(all: t) }
        // unique names (first wins)
        var seen = Set<String>()
        return t.filter { seen.insert($0.name).inserted }
    }
}

/// Destructive-action confirmation shown in the app (never auto-approved).
@MainActor enum Confirm {
    /// Only the self test sets this (to answer its own prompts); nil in normal use.
    static var autoAnswer: Bool?
    static func ask(_ title: String, _ detail: String) -> Bool {
        if let a = autoAnswer { return a }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.alertStyle = .warning
        a.addButton(withTitle: "Allow once")
        a.addButton(withTitle: "Deny")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }
}


/// Recognises plain computer-action requests ("open safari", "type hello", "what's on my screen").
enum Intent {
    static let actionRe = #"\b(open|launch|start|run|execute|shell|terminal|command|quit|close|kill|list|show|read|create|make|new|write|save|delete|trash|remove|move|rename|copy|paste|type|write|click|press|screenshot|screen|clipboard|tab|browser|safari|chrome|folder|directory|desktop|downloads|documents|file|app|search|google|look ?up|find|pc|computer|mac)\b"#
    static func isAction(_ text: String) -> Bool { text.lowercased().range(of: actionRe, options: .regularExpression) != nil }
    /// Assistant text that refuses or only narrates instead of acting.
    static func isEvasive(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.range(of: #"(don't|do not|cannot|can't|unable to|not able to)[^.]{0,40}(access|control|interact|open|run|perform|do that)|as an ai|i'll use|i will use|let me use|please wait|follow these steps|you can use the|in the terminal|pc_[a-z_]+"#, options: .regularExpression) != nil
    }
    static func first(_ s: String, _ re: String) -> [String]? {
        guard let r = try? NSRegularExpression(pattern: re, options: [.caseInsensitive]),
              let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }
    static func clean(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: " .!?\"'")).trimmingCharacters(in: .whitespaces) }
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// A concrete tool call for simple requests, used when the model fails to call a tool itself.
    static func guess(_ raw: String) -> Agent.Call? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func c(_ n: String, _ a: [String: Any]) -> Agent.Call { Agent.Call(id: "fb_intent", name: n, args: a) }
        func google(_ x: String) -> Agent.Call { c("pc_open_url", ["url": "https://www.google.com/search?q=" + (clean(x).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")]) }
        if let m = first(s, #"^(?:hey\s+|please\s+|can you\s+|could you\s+|now\s+)*type\s+(?:out\s+)?(?:the\s+(?:text|word)s?\s+)?["“]?(.+?)["”]?\s*$"#) { return c("pc_type_text", ["text": m[1]]) }
        if first(s, #"what'?s on (?:my |the )?screen|what is on (?:my |the )?screen|screenshot|see my screen|look at my screen|read my screen"#) != nil { return c("pc_screenshot", [:]) }
        if let m = first(s, #"(?:make|create|new)\s+(?:a\s+)?(?:new\s+)?folder(?:\s+(?:called|named)\s+["“]?([^"”]+?)["”]?)?\s+(?:on|in)\s+(?:my\s+|the\s+)?(desktop|downloads|documents)(?:\s+(?:called|named)\s+["“]?([^"”]+?)["”]?)?\s*[.!]?$"#) {
            let name = clean(m[1].isEmpty ? (m[3].isEmpty ? "New Folder" : m[3]) : m[1]); let base = "~/" + m[2].capitalized
            return c("pc_shell", ["command": "mkdir -p \(base)/\(q(name)) && echo created \(base)/\(q(name))"])
        }
        if let m = first(s, #"search\s+(?:my\s+)?(?:pc|mac|computer)\s+for\s+(?:my\s+)?(.+?)(?:\s+(?:app|application))?(?:\s+and\s+.*)?$"#) {
            return c("pc_shell", ["command": "mdfind -name \(q(clean(m[1]))) | head -20"])
        }
        if let m = first(s, #"(?:open|launch)\s+(?:my\s+|the\s+)?(?:default\s+)?browser(?:\s+and\s+(?:search|look)\s*(?:up|for)?\s+(.+))?$"#) {
            return m[1].isEmpty ? c("pc_open_url", ["url": "https://www.google.com"]) : google(m[1])
        }
        if let m = first(s, #"^(?:hey\s+|please\s+|can you\s+|could you\s+)*(?:search|google|look\s*up)\s+(?:up\s+|for\s+)?(.+?)(?:\s+(?:and|then)\s+.*)?$"#) { return google(m[1]) }
        if let m = first(s, #"\b(?:go to|open|visit)\s+((?:https?://)?[a-z0-9-]+\.[a-z]{2,}\S*)"#) { return c("pc_open_url", ["url": m[1].hasPrefix("http") ? m[1] : "https://" + m[1]]) }
        if let m = first(s, #"\b(?:quit|close|kill)\s+(?:my\s+|the\s+)?([a-z0-9 .]+?)(?:\s+app(?:lication)?)?(?:\s+(?:i have open|that'?s open|please))?\s*[.!?]?$"#) { return c("pc_quit_app", ["name": clean(m[1])]) }
        if let m = first(s, #"\b(?:open|launch|start)\s+(?:up\s+)?(?:my\s+|the\s+)?([a-z0-9 .]+?)(?:\s+app(?:lication)?)?\s*[.!?]?$"#) { return c("pc_open_app", ["name": clean(m[1])]) }
        return nil
    }
}

/// Tool-calling loop: native OpenAI tool_calls when the model supports them, otherwise a
/// <tool_call>{"name":…,"arguments":{…}}</tool_call> text protocol so any model can use tools.
enum Agent {
    static let maxSteps = 8

    static func fallbackInstructions(_ tools: [ToolSpec]) -> String {
        let list = tools.map { t -> String in
            let props = (t.schema["properties"] as? [String: Any]).map { Array($0.keys).sorted().joined(separator: ", ") } ?? ""
            return "- \(t.name)(\(props)): \(t.description)"
        }.joined(separator: "\n")
        let pc = tools.contains { $0.source.hasPrefix("pc:") }
        return (pc ? "IMPORTANT: You are running inside the Red-XAI Vortex app on the user's Mac and you DO have full control of it through the pc_ tools below. Do exactly what the user asks, literally, right away. When the user asks for anything on the computer (open/quit apps, files, folders, desktop, shell, typing, clicking, what is on screen, browser, web search, clipboard), your reply must be ONLY a <tool_call>. Do not describe what you will do, do not say please wait, do not give instructions. To search the web call pc_open_url with https://www.google.com/search?q=... To find something on the Mac call pc_shell with mdfind -name. You can operate this Mac with the pc_ tools. When the user asks you to do anything on the computer (files, folders, apps, shell, typing, clicking, screen, browser, clipboard), do it by calling a tool instead of explaining how. Never say you cannot access the computer. Never guess or invent a result: to run a command you must call pc_shell and report its real output. Use ~ for the home folder.\n" : "") + """
        You can use tools. To call one, reply with ONLY this (one call per reply):
        <tool_call>{"name": "TOOL_NAME", "arguments": {"arg": "value"}}</tool_call>
        You will get the result in a message starting with TOOL_RESULT. Tool results are correct: use them exactly as given and never recompute or "correct" them. Then continue, or answer normally when done.
        Tools:
        \(list)
        """
    }

    struct Call { var id: String; var name: String; var args: [String: Any] }

    static func parseFallback(_ content: String, names: Set<String>) -> Call? {
        var js: Substring?
        if let a = content.range(of: "<tool_call>") {
            let end = content.range(of: "</tool_call>", range: a.upperBound..<content.endIndex)?.lowerBound ?? content.endIndex
            js = content[a.upperBound..<end]
        } else if let a = content.firstIndex(of: "{"), let b = content.lastIndex(of: "}"), a < b {
            js = content[a...b]   // bare JSON (some models drop the tags or wrap it in ```json)
        }
        guard let j = js?.trimmingCharacters(in: .whitespacesAndNewlines),
              let o = try? JSONSerialization.jsonObject(with: Data(j.utf8)) as? [String: Any] else { return nil }
        let fn = o["function"] as? [String: Any]
        guard let n = (o["name"] ?? o["tool"] ?? fn?["name"]) as? String, names.contains(n) else { return nil }
        var args = (o["arguments"] ?? o["parameters"] ?? fn?["arguments"]) as? [String: Any] ?? [:]
        if args.isEmpty, let s = (o["arguments"] ?? fn?["arguments"]) as? String, let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] { args = d }
        return Call(id: "fb_" + UUID().uuidString.prefix(8), name: n, args: args)
    }

    /// Runs the loop; returns final text plus a short step log. `onStep` reports progress.
    static func run(_ p: ChatParams, history: [Message], tools: [ToolSpec],
                    onStep: @escaping @Sendable (String) -> Void) async throws -> (String, [String]) {
        let hasPC = tools.contains { $0.source.hasPrefix("pc:") }
        var msgs: [[String: Any]] = []
        for (n, m) in history.enumerated() {
            if hasPC, m.role == "assistant", Intent.isEvasive(m.content), (m.toolLog ?? []).isEmpty {
                if let l = msgs.last, l["role"] as? String == "user" { msgs.removeLast() }   // drop the failed exchange
                continue
            }
            _ = n; msgs.append(["role": m.role, "content": m.apiContent])
        }
        let lastUser = history.last(where: { $0.role == "user" })?.content ?? ""
        let fb = fallbackInstructions(tools)
        if let i = msgs.firstIndex(where: { $0["role"] as? String == "system" }) {
            msgs[i]["content"] = tools.contains(where: { $0.source.hasPrefix("pc:") }) ? fb + "\n\n" + ((msgs[i]["content"] as? String) ?? "") + "\n\nReminder: for computer actions reply only with a <tool_call>." : ((msgs[i]["content"] as? String) ?? "") + "\n\n" + fb
        } else { msgs.insert(["role": "system", "content": fb], at: 0) }
        // llama.cpp Mixtral-family models (vortex, red-xai) follow a worked example far better than a schema.
        let textOnly = PCControl.eligible(p.model)
        if textOnly, tools.contains(where: { $0.name == "pc_list_dir" }) {
            let ex: [[String: Any]] = [
                ["role": "user", "content": "What's in my Downloads folder?"],
                ["role": "assistant", "content": "<tool_call>{\"name\": \"pc_list_dir\", \"arguments\": {\"path\": \"~/Downloads\"}}</tool_call>"],
                ["role": "user", "content": "TOOL_RESULT pc_list_dir (exact; use it as is):\n📄 report.pdf (2048 B)\n📁 photos"],
                ["role": "assistant", "content": "Your Downloads folder has report.pdf and a photos folder."],
                ["role": "user", "content": "open notes"],
                ["role": "assistant", "content": "<tool_call>{\"name\": \"pc_open_app\", \"arguments\": {\"name\": \"Notes\"}}</tool_call>"],
                ["role": "user", "content": "TOOL_RESULT pc_open_app (exact; use it as is):\nopened Notes"],
                ["role": "assistant", "content": "Done, Notes is open."]]
            let at = (msgs.firstIndex(where: { $0["role"] as? String == "system" }) ?? -1) + 1
            msgs.insert(contentsOf: ex, at: at)
        }
        let toolDefs: [[String: Any]] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] }
        var log: [String] = []
        var native = !textOnly
        var retried = false
        var nudges = 0
        func execute(_ calls: [Call]) async throws {
            for c in calls {
                var c = c
                for (k, alts) in ["name": ["app", "application", "app_name", "appName"], "path": ["folder", "dir", "directory", "file", "filepath", "file_path"],
                                  "url": ["link", "website", "address"], "command": ["cmd", "shell", "script"], "text": ["content", "string", "value"]] where c.args[k] == nil {
                    if let v = alts.lazy.compactMap({ c.args[$0] }).first { c.args[k] = v }
                }
                guard let t = tools.first(where: { $0.name == c.name }) else {
                    let r = "error: no tool named \(c.name)"
                    append(&msgs, c, r); log.append("✗ \(c.name): unknown tool"); continue
                }
                let argText = (try? JSONSerialization.data(withJSONObject: c.args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                if let k = PCKind(source: t.source), !(await MainActor.run { PCControl.shared.isOn(k) }) {
                    append(&msgs, c, "error: \"\(k.title)\" is switched off. Tell the user to press the Turn on button shown below your reply, then ask again.")
                    log.append(PCControl.offMarker + k.rawValue); PCControl.logAction("\(t.name) blocked: \(k.rawValue) is off"); continue
                }
                if t.destructive {
                    let ok = await MainActor.run { Confirm.ask("Allow \(t.name)?", "The model wants to run \(t.name) (\(t.source)) with:\n\(argText.prefix(600))") }
                    if !ok { append(&msgs, c, "error: the user denied this action"); log.append("⛔ \(t.name) denied"); PCControl.logAction("\(t.name) DENIED \(argText.prefix(200))"); continue }
                }
                onStep("Running \(t.name)…")
                var result: String
                do { result = try await t.run(c.args) } catch { result = "error: \(error.localizedDescription)" }
                if t.source.hasPrefix("pc:") { PCControl.logAction("\(t.name) \(argText.prefix(200)) → \(result.prefix(120))") }
                if result.count > 16000 { result = String(result.prefix(16000)) + "\n…[truncated]" }
                log.append("🔧 \(t.name)(\(argText.prefix(120))) → \(result.prefix(160).replacingOccurrences(of: "\n", with: " "))")
                append(&msgs, c, result)
            }
        }
        for step in 0..<maxSteps {
            try Task.checkCancellation()
            onStep(step == 0 ? "Thinking (tools on)…" : "Thinking after \(log.count) tool call(s)…")
            if step == 0, hasPC, log.isEmpty, let g = Intent.guess(lastUser), tools.contains(where: { $0.name == g.name }) {
                // Plain, unambiguous request ("open safari", "type hello"): act first, then let the model report.
                let argJSON = (try? JSONSerialization.data(withJSONObject: g.args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                msgs.append(["role": "assistant", "content": "<tool_call>{\"name\": \"\(g.name)\", \"arguments\": \(argJSON)}</tool_call>"])
                try await execute([g]); continue
            }
            let j = try await complete(p, messages: msgs, tools: native ? toolDefs : [])
            let msg = ((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
            let content = (msg["content"] as? String) ?? ""
            // Some models return nothing when given native tool definitions: retry once with the text protocol only.
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (msg["tool_calls"] as? [Any] ?? []).isEmpty && !retried {
                retried = true; native = false; continue
            }
            var calls: [Call] = []
            if let tc = msg["tool_calls"] as? [[String: Any]], !tc.isEmpty {
                for c in tc {
                    let f = c["function"] as? [String: Any] ?? [:]
                    let argStr = f["arguments"] as? String ?? "{}"
                    let args = (try? JSONSerialization.jsonObject(with: Data(argStr.utf8)) as? [String: Any]) ?? (f["arguments"] as? [String: Any] ?? [:])
                    calls.append(Call(id: c["id"] as? String ?? UUID().uuidString, name: f["name"] as? String ?? "", args: args))
                }
                var am = msg; am["content"] = content
                msgs.append(am)
            } else if let c = parseFallback(content, names: Set(tools.map(\.name))) {
                calls = [c]
                msgs.append(["role": "assistant", "content": content])
            } else if hasPC, log.isEmpty, Intent.isAction(lastUser), let g = Intent.guess(lastUser), tools.contains(where: { $0.name == g.name }) {
                // Simple request and the model didn't act: do it directly.
                calls = [g]
                msgs.append(["role": "assistant", "content": "<tool_call>{\"name\": \"\(g.name)\", \"arguments\": \((try? JSONSerialization.data(withJSONObject: g.args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")}</tool_call>"])
            } else if hasPC, nudges < 2, (log.isEmpty && Intent.isAction(lastUser)) || Intent.isEvasive(content) {
                nudges += 1
                msgs.append(["role": "assistant", "content": content])
                msgs.append(["role": "user", "content": "You have NOT done it yet, and you DO have access. Do it now: reply with only <tool_call>{\"name\": \"pc_...\", \"arguments\": {...}}</tool_call> using one of the listed tools."])
                continue
            } else {
                let clean = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("TOOL_RESULT") }
                return (clean.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), log)
            }
            try await execute(calls)
        }
        return ("(Stopped after \(maxSteps) tool steps.)", log)
    }

    static func append(_ msgs: inout [[String: Any]], _ c: Call, _ result: String) {
        if c.id.hasPrefix("fb_") { msgs.append(["role": "user", "content": "TOOL_RESULT \(c.name) (exact; use it as is):\n\(result)"]) }
        else { msgs.append(["role": "tool", "tool_call_id": c.id, "name": c.name, "content": result]) }
    }

    static func complete(_ p: ChatParams, messages: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
        guard let u = API.url(p.baseURL, "/chat/completions") else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !p.apiKey.isEmpty { r.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = ["model": p.model, "messages": messages, "temperature": p.temperature, "max_tokens": p.maxTokens, "stream": false]
        if !tools.isEmpty { body["tools"] = tools }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        var attempt = 0
        while true {
            let (d, resp) = try await URLSession.shared.data(for: r)
            let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code < 300 { return j }
            if code >= 500 && attempt < 2 {   // model loading/unloading on the server
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(6 * attempt) * 1_000_000_000)
                continue
            }
            let m = code >= 500
                ? "Vortex is loading this model on the server (it retried \(attempt + 1)×). Please send again in a few seconds."
                : (((j["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)")
            throw NSError(domain: "Vortex", code: code, userInfo: [NSLocalizedDescriptionKey: m])
        }
    }
}
