import SwiftUI
import JavaScriptCore

// MARK: - Manifest

/// plugin.json — a plugin is a set of tools the model can call.
/// Tool kinds: "builtin" (shipped in the app), "http" (URL template, args filled in), "js" (sandboxed JavaScript, no network/files).
struct PluginTool: Codable, Hashable {
    var name: String
    var description: String
    var parameters: [String: AnyCodable] = ["type": AnyCodable("object"), "properties": AnyCodable([String: Any]())]
    var kind: String                  // builtin | http | js
    var builtin: String? = nil        // builtin id
    var url: String? = nil            // http: https://…?q={query}
    var method: String? = nil         // http: GET/POST
    var code: String? = nil           // js: function run(args) { return … }
}
struct PluginManifest: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var version: String = "1.0.0"
    var description: String
    var author: String = "Red-XAI Vortex"
    var icon: String = "puzzlepiece"
    var tools: [PluginTool]
}

/// Minimal Any wrapper so JSON Schemas round-trip through Codable.
struct AnyCodable: Codable, Hashable {
    let value: Any
    init(_ v: Any) { value = v }
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let x = try? c.decode(Double.self) { value = x }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) }
        else if let o = try? c.decode([String: AnyCodable].self) { value = o.mapValues(\.value) }
        else { value = NSNull() }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch value {
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let x as Double: try c.encode(x)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map { AnyCodable($0) })
        case let o as [String: Any]: try c.encode(o.mapValues { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }
    static func == (a: AnyCodable, b: AnyCodable) -> Bool { String(describing: a.value) == String(describing: b.value) }
    func hash(into h: inout Hasher) { h.combine(String(describing: value)) }
}
extension PluginTool {
    init(_ name: String, _ desc: String, props: [String: [String: String]], required: [String], kind: String, builtin: String? = nil, url: String? = nil, code: String? = nil) {
        self.name = name; self.description = desc; self.kind = kind; self.builtin = builtin; self.url = url; self.code = code
        self.parameters = ["type": AnyCodable("object"), "properties": AnyCodable(props as [String: Any]), "required": AnyCodable(required)]
    }
    var schema: [String: Any] { parameters.mapValues(\.value) }
}

// MARK: - Starter catalog (the Plugin Store)

enum PluginCatalog {
    static let starters: [PluginManifest] = [
        .init(id: "web-search", name: "Web Search", description: "Search the web (DuckDuckGo) and return top results with links.", icon: "magnifyingglass",
              tools: [.init("web_search", "Search the web. Returns titles, links and snippets.", props: ["query": ["type": "string", "description": "search terms"]], required: ["query"], kind: "builtin", builtin: "web_search"),
                      .init("fetch_url", "Fetch a web page and return its readable text.", props: ["url": ["type": "string"]], required: ["url"], kind: "builtin", builtin: "fetch_url")]),
        .init(id: "file-reader", name: "File Reader", description: "Read text, code and PDF files in your home folder (read-only; hidden folders like ~/.ssh are blocked).", icon: "doc.text.magnifyingglass",
              tools: [.init("read_file", "Read a file from the user's home folder. Path may start with ~.", props: ["path": ["type": "string"]], required: ["path"], kind: "builtin", builtin: "read_file"),
                      .init("list_folder", "List files in a folder in the user's home folder.", props: ["path": ["type": "string"]], required: ["path"], kind: "builtin", builtin: "list_folder")]),
        .init(id: "calculator", name: "Calculator", description: "Exact arithmetic and math functions (sqrt, sin, log, pow…).", icon: "function",
              tools: [.init("calculator", "Evaluate a math expression, e.g. (2+3)*sqrt(16)/log(10).", props: ["expression": ["type": "string"]], required: ["expression"], kind: "builtin", builtin: "calculator")]),
        .init(id: "weather", name: "Weather", description: "Current weather and 3-day forecast for any city (Open-Meteo, no key).", icon: "cloud.sun",
              tools: [.init("weather", "Get current weather and a 3-day forecast for a place.", props: ["place": ["type": "string", "description": "city name"]], required: ["place"], kind: "builtin", builtin: "weather")]),
        .init(id: "datetime", name: "Date & Time", description: "Current date/time and time-zone conversion.", icon: "clock",
              tools: [.init("now", "Current date and time, optionally in an IANA time zone.", props: ["timezone": ["type": "string"]], required: [], kind: "js",
                            code: "function run(a){ var o={timeZone:a.timezone||undefined, dateStyle:'full', timeStyle:'long'}; try { return new Intl.DateTimeFormat('en-US',o).format(new Date()); } catch(e) { return new Date().toString(); } }")]),
        .init(id: "wikipedia", name: "Wikipedia", description: "Short summary of a Wikipedia article.", icon: "book",
              tools: [.init("wikipedia", "Summary of the Wikipedia article for a title.", props: ["title": ["type": "string"]], required: ["title"], kind: "http",
                            url: "https://en.wikipedia.org/api/rest_v1/page/summary/{title}")]),
    ]
}

// MARK: - Store

@MainActor final class PluginStore: ObservableObject {
    static let shared = PluginStore()
    @Published var installed: [PluginManifest] = []
    @Published var enabled: Set<String> = []          // mode != off
    @Published var modes: [String: String] = [:]      // plugin id -> always | auto | off
    @Published var message = ""
    var dir: URL { let d = ChatStore.dir.appendingPathComponent("plugins", isDirectory: true); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }

    init() { load() }
    func load() {
        let fm = FileManager.default
        installed = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("plugin.json")) else { return nil }
            return try? JSONDecoder().decode(PluginManifest.self, from: data)
        }.sorted { $0.name < $1.name }
        modes = AccountProfile.preferences.dictionary(forKey: "pluginModes") as? [String: String] ?? [:]
        if modes.isEmpty { for id in AccountProfile.preferences.stringArray(forKey: "pluginsEnabled") ?? [] { modes[id] = "auto" } } // migrate old on/off
        enabled = Set(modes.filter { $0.value != "off" }.keys)
        if AccountProfile.preferences.object(forKey: "pluginsSeeded") == nil {   // first run: install the starters, enabled off
            AccountProfile.preferences.set(true, forKey: "pluginsSeeded")
            for p in PluginCatalog.starters { try? install(p, enable: false) }
        }
    }
    func validate(_ p: PluginManifest) throws {
        guard p.id.range(of: "^[a-z0-9-]{2,40}$", options: .regularExpression) != nil else { throw err("Plugin id must be a-z, 0-9 and - (2–40 chars).") }
        guard !p.tools.isEmpty else { throw err("A plugin needs at least one tool.") }
        for t in p.tools {
            guard t.name.range(of: "^[a-zA-Z0-9_]{1,48}$", options: .regularExpression) != nil else { throw err("Tool name \(t.name) must be letters, digits or _.") }
            switch t.kind {
            case "builtin": guard Builtins.ids.contains(t.builtin ?? "") else { throw err("Unknown builtin \(t.builtin ?? "")") }
            case "http": guard let u = t.url, u.hasPrefix("https://") || u.hasPrefix("http://127.0.0.1") else { throw err("HTTP tools need an https:// URL.") }
            case "js": guard (t.code ?? "").contains("function run") else { throw err("JS tools need function run(args) { … }") }
            default: throw err("Tool kind must be builtin, http or js.")
            }
        }
    }
    func install(_ p: PluginManifest, enable: Bool = true) throws {
        try validate(p)
        let d = dir.appendingPathComponent(p.id, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(p).write(to: d.appendingPathComponent("plugin.json"), options: .atomic)
        installed.removeAll { $0.id == p.id }; installed.append(p); installed.sort { $0.name < $1.name }
        if enable { setEnabled(p.id, true) }
        message = "Installed \(p.name)."
    }
    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id))
        installed.removeAll { $0.id == id }; setEnabled(id, false); message = "Removed \(id)."
    }
    func setEnabled(_ id: String, _ on: Bool) { setMode(id, on ? (modes[id] == "always" ? "always" : "auto") : "off") }
    func mode(_ id: String) -> String { modes[id] ?? "off" }
    func setMode(_ id: String, _ m: String) {
        modes[id] = m; enabled = Set(modes.filter { $0.value != "off" }.keys)
        AccountProfile.preferences.set(modes, forKey: "pluginModes"); AccountProfile.preferences.set(Array(enabled), forKey: "pluginsEnabled")
    }
    var alwaysOn: [PluginManifest] { installed.filter { mode($0.id) == "always" } }
    func importFile(_ url: URL) {
        do { let p = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url)); try install(p) }
        catch { message = "Import failed: \(error.localizedDescription)" }
    }
    func enabledTools() -> [ToolSpec] {
        installed.filter { enabled.contains($0.id) }.flatMap { p in p.tools.map { t in
            ToolSpec(name: t.name, description: t.description, schema: t.schema, source: "plugin:\(p.id)") { args in try await PluginRunner.run(t, args) }
        } }
    }
    func err(_ m: String) -> NSError { NSError(domain: "Vortex", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }

    // MARK: Plugin Maker — the active Vortex model writes the manifest
    func make(description: String) async throws -> PluginManifest {
        let prompt = """
        Write a Red-XAI Vortex plugin manifest as JSON only (no prose, no code fences).
        Schema: {"id":"kebab-id","name":"Name","version":"1.0.0","description":"…","author":"Vortex Plugin Maker","icon":"SF Symbol name",
        "tools":[{"name":"snake_name","description":"…","parameters":{"type":"object","properties":{"arg":{"type":"string","description":"…"}},"required":["arg"]},
        "kind":"js","code":"function run(args){ … return 'text result'; }"}]}
        Rules: kind is "js" (pure JavaScript, no network, no require/import, return a string) or "http" with "url":"https://…{arg}…" and "method":"GET" for public no-key JSON APIs.
        Plugin to build: \(description)
        """
        let srv = ServerStore.shared.active
        let base = srv?.chatURL ?? (AccountProfile.preferences.string(forKey: "serverURL") ?? Defaults.serverURL)
        // Prefer Keychain (same key SelfTest / chat use); ServerStore.key can be empty when Link is on.
        let key: String = {
            if let k = Keychain.get(), !k.isEmpty { return k }
            if let s = srv {
                let k = ServerStore.shared.key(for: s)
                if !k.isEmpty { return k }
            }
            return ""
        }()
        let p = ChatParams(baseURL: base, apiKey: key, model: AccountProfile.preferences.string(forKey: "pluginMakerModel") ?? "vortex",
                           temperature: 0.2, topP: 0.9, repeatPenalty: 1.05, topK: 40, maxTokens: 1500, seed: -1)
        let j = try await Agent.complete(p, messages: [["role": "user", "content": prompt]], tools: [])
        var txt = (((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        if let a = txt.firstIndex(of: "{"), let b = txt.lastIndex(of: "}") { txt = String(txt[a...b]) }
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(txt.utf8))
        try validate(m)
        return m
    }

    // MARK: Plugin Store (Vultr) — upload / My plugins / install
    @Published var storeList: [StorePlugin] = []
    @Published var myList: [StorePlugin] = []
    @Published var myUser = ""
    @Published var needSignIn = false
    private var pending: (() async -> Void)?

    /// Runs a store call; on NeedSignIn shows the inline RedX sheet and retries after sign-in.
    func gated(_ f: @escaping () async throws -> Void) async {
        do { try await f() }
        catch is StoreNet.NeedSignIn { pending = { [weak self] in await self?.gated(f) }; needSignIn = true }
        catch { message = "Store: \(error.localizedDescription)" }
    }
    func signInFinished(_ ok: Bool) {
        needSignIn = false
        if ok, let p = pending { pending = nil; Task { await p() } } else { pending = nil; message = StoreNet.signInMsg }
    }
    func uploadToStore(_ p: PluginManifest, iconDataURL: String?) async {
        await gated { [self] in
            var d = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(p))) as? [String: Any] ?? [:]
            d.removeValue(forKey: "author")   // the store sets author = your RedX username
            d["icon"] = iconDataURL ?? StoreNet.fit256(StoreNet.defaultIcon())?.0
            let r = try await StoreNet.req("POST", "", body: d)
            let pl = StorePlugin((r["plugin"] as? [String: Any]) ?? [:])
            message = "Published \(pl.name) as \(pl.author)."
            await refreshStore(); await refreshMine()
        }
    }
    func refreshStore() async {
        do { let r = try await StoreNet.req("GET", "", auth: false); storeList = ((r["plugins"] as? [[String: Any]]) ?? []).map(StorePlugin.init) }
        catch { message = "Store unreachable: \(error.localizedDescription)" }
    }
    func refreshMine() async {
        await gated { [self] in
            let r = try await StoreNet.req("GET", "?mine=1")
            myUser = r["username"] as? String ?? ""; myList = ((r["plugins"] as? [[String: Any]]) ?? []).map(StorePlugin.init)
        }
    }
    func editStore(_ id: String, _ patch: [String: Any]) async {
        await gated { [self] in _ = try await StoreNet.req("PUT", "/\(id)", body: patch); message = "Saved \(id)."; await refreshMine(); await refreshStore() }
    }
    func unpublish(_ id: String) async {
        await gated { [self] in _ = try await StoreNet.req("DELETE", "/\(id)"); message = "Unpublished \(id)."; await refreshMine(); await refreshStore() }
    }
    func installFromStore(_ id: String) async {
        do {
            let r = try await StoreNet.req("GET", "/\(id)", auth: false)
            var d = r; d.removeValue(forKey: "icon"); d["icon"] = "puzzlepiece"
            if d["author"] == nil { d["author"] = d["uploader"] ?? "Red-XAI" }
            if d["version"] == nil { d["version"] = "1.0.0" }
            for k in ["hasIcon", "installs", "published", "updated", "uploader"] { d.removeValue(forKey: k) }
            let m = try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: d))
            try install(m)
            _ = try? await StoreNet.req("POST", "/\(id)/install", auth: false)
            message = "Installed \(m.name)."; await refreshStore()
        } catch { message = "Install failed: \(error.localizedDescription)" }
    }
    func genIcon(_ prompt: String) async throws -> NSImage {
        let srv = ServerStore.shared.active
        let base = srv?.chatURL ?? (AccountProfile.preferences.string(forKey: "serverURL") ?? Defaults.serverURL)
        let key = Keychain.get() ?? srv.map { ServerStore.shared.key(for: $0) } ?? ""
        guard let u = URL(string: base + "/images/generations") else { throw err("Bad server URL") }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 180
        r.setValue("application/json", forHTTPHeaderField: "Content-Type"); if !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        r.httpBody = try JSONSerialization.data(withJSONObject: ["model": "vortex-image", "prompt": "flat app icon, centered, dark background, red accent: " + prompt, "size": "256x256", "n": 1, "response_format": "b64_json"])
        let (d, _) = try await URLSession.shared.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        guard let b = ((j?["data"] as? [[String: Any]])?.first?["b64_json"] as? String), let data = Data(base64Encoded: b), let img = NSImage(data: data) else { throw err("Image generation failed") }
        return img
    }

}

// MARK: - Runner

enum PluginRunner {
    static func run(_ t: PluginTool, _ args: [String: Any]) async throws -> String {
        switch t.kind {
        case "builtin": return try await Builtins.run(t.builtin ?? "", args)
        case "http":
            var s = t.url ?? ""
            for (k, v) in args { s = s.replacingOccurrences(of: "{\(k)}", with: "\(v)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&=#"))) ?? "") }
            guard let u = URL(string: s) else { throw URLError(.badURL) }
            var r = URLRequest(url: u); r.httpMethod = t.method ?? "GET"; r.timeoutInterval = 30
            r.setValue("Red-XAI-Vortex/2.2", forHTTPHeaderField: "User-Agent")
            let (d, _) = try await URLSession.shared.data(for: r)
            return String(data: d.prefix(60_000), encoding: .utf8) ?? "(binary response)"
        case "js":
            return try JSRunner.run(t.code ?? "", args)
        default: throw URLError(.unsupportedURL)
        }
    }
}

/// JavaScriptCore sandbox: no network, no file access, 5 s budget.
enum JSRunner {
    static func run(_ code: String, _ args: [String: Any]) throws -> String {
        guard let ctx = JSContext() else { throw URLError(.cannotLoadFromNetwork) }
        var exc: String?
        ctx.exceptionHandler = { _, e in exc = e?.toString() }
        if let group = JSContextGetGroup(ctx.jsGlobalContextRef) {
            JSContextGroupSetExecutionTimeLimit(group, 5, { _, _ in true }, nil)   // terminate scripts after 5 s
        }
        ctx.evaluateScript(code)
        let a = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let r = ctx.evaluateScript("(function(){ var r = run(\(a)); return typeof r === 'string' ? r : JSON.stringify(r); })()")
        if let exc { throw NSError(domain: "Vortex", code: 2, userInfo: [NSLocalizedDescriptionKey: "JS error: \(exc)"]) }
        return r?.toString() ?? ""
    }
}

// Private JSC API for the time limit (stable since macOS 10.6).
@_silgen_name("JSContextGroupSetExecutionTimeLimit")
func JSContextGroupSetExecutionTimeLimit(_ group: JSContextGroupRef, _ limit: Double, _ cb: (@convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool)?, _ ctx: UnsafeMutableRawPointer?)

// MARK: - Built-in tools

enum Builtins {
    static let ids: Set<String> = ["web_search", "fetch_url", "read_file", "list_folder", "calculator", "weather"]

    static func run(_ id: String, _ a: [String: Any]) async throws -> String {
        let s: (String) -> String = { (a[$0] as? String) ?? (a[$0].map { "\($0)" } ?? "") }
        switch id {
        case "calculator": return try calc(s("expression"))
        case "web_search": return try await search(s("query"))
        case "fetch_url": return try await fetch(s("url"))
        case "read_file": return try readFile(s("path"))
        case "list_folder": return try listFolder(s("path"))
        case "weather": return try await weather(s("place"))
        default: throw URLError(.unsupportedURL)
        }
    }

    static func calc(_ e: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/%^() ,eE").union(.letters)
        guard !e.isEmpty, e.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw err("Only numbers, operators and math functions are allowed.") }
        let words = Set(e.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        let fns: Set<String> = ["sqrt", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "log", "ln", "log10", "log2", "exp", "abs", "floor", "ceil", "round", "pow", "min", "max", "pi", "PI", "e", "E"]
        guard words.isSubset(of: fns) else { throw err("Unknown function: \(words.subtracting(fns).joined(separator: ", "))") }
        let js = "with(Math){ var ln=log; var pi=PI; var log10=Math.log10; (\(e.replacingOccurrences(of: "^", with: "**"))) }"
        let ctx = JSContext()!
        var ex: String?; ctx.exceptionHandler = { _, v in ex = v?.toString() }
        let r = ctx.evaluateScript(js)
        if let ex { throw err(ex) }
        return r?.toString() ?? "NaN"
    }

    static func get(_ u: URL) async throws -> Data {
        var r = URLRequest(url: u); r.timeoutInterval = 25
        r.setValue("Mozilla/5.0 (Macintosh) Red-XAI-Vortex/2.2", forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: r).0
    }
    static func search(_ q: String) async throws -> String {
        guard let u = URL(string: "https://html.duckduckgo.com/html/?q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) else { throw URLError(.badURL) }
        let html = String(data: try await get(u), encoding: .utf8) ?? ""
        let link = try NSRegularExpression(pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let snip = try NSRegularExpression(pattern: #"class="result__snippet"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        let links = link.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let snips = snip.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [String] = []
        for (i, m) in links.prefix(6).enumerated() {
            var href = ns.substring(with: m.range(at: 1))
            if let c = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href), let ud = c.queryItems?.first(where: { $0.name == "uddg" })?.value { href = ud }
            let title = strip(ns.substring(with: m.range(at: 2)))
            let sn = i < snips.count ? strip(ns.substring(with: snips[i].range(at: 1))) : ""
            out.append("\(i + 1). \(title)\n   \(href)\n   \(sn)")
        }
        return out.isEmpty ? "No results." : out.joined(separator: "\n")
    }
    static func strip(_ h: String) -> String {
        var s = h.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] { s = s.replacingOccurrences(of: a, with: b) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func fetch(_ s: String) async throws -> String {
        guard let u = URL(string: s), ["http", "https"].contains(u.scheme ?? "") else { throw err("Only http(s) URLs.") }
        let d = try await get(u)
        var h = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
        h = h.replacingOccurrences(of: "(?is)<(script|style|noscript)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        let t = strip(h).replacingOccurrences(of: "\\s{2,}", with: "\n", options: .regularExpression)
        return String(t.prefix(20000))
    }
    static func safePath(_ p: String) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let full = ((p as NSString).expandingTildeInPath as NSString).standardizingPath
        let real = (full as NSString).resolvingSymlinksInPath
        guard real.hasPrefix(home + "/") || real == home else { throw err("Only files inside your home folder can be read.") }
        let rel = real.dropFirst(home.count)
        if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) || rel.contains("/Library/Keychains") { throw err("Hidden folders (like ~/.ssh) and keychains are blocked.") }
        return real
    }
    static func readFile(_ p: String) throws -> String {
        let path = try safePath(p)
        let a = try AttachmentLoader.loadSync(URL(fileURLWithPath: path))
        guard a.kind == "text" else { throw err("That's an image; attach it with + instead.") }
        return String((a.text ?? "").prefix(30000))
    }
    static func listFolder(_ p: String) throws -> String {
        let path = try safePath(p.isEmpty ? "~" : p)
        let items = try FileManager.default.contentsOfDirectory(atPath: path).filter { !$0.hasPrefix(".") }.sorted()
        return items.prefix(300).map { n in
            var d: ObjCBool = false; FileManager.default.fileExists(atPath: path + "/" + n, isDirectory: &d)
            return d.boolValue ? n + "/" : n
        }.joined(separator: "\n")
    }
    static func weather(_ place: String) async throws -> String {
        let q = place.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let g = try JSONSerialization.jsonObject(with: try await get(URL(string: "https://geocoding-api.open-meteo.com/v1/search?count=1&name=\(q)")!)) as? [String: Any]
        guard let r = (g?["results"] as? [[String: Any]])?.first, let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { throw err("Place not found: \(place)") }
        let f = try JSONSerialization.jsonObject(with: try await get(URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code&timezone=auto&forecast_days=3")!)) as? [String: Any]
        let c = f?["current"] as? [String: Any] ?? [:], d = f?["daily"] as? [String: Any] ?? [:]
        let name = [r["name"], r["admin1"], r["country"]].compactMap { $0 as? String }.joined(separator: ", ")
        var out = "\(name): now \(c["temperature_2m"] ?? "?")°C (feels \(c["apparent_temperature"] ?? "?")°C), humidity \(c["relative_humidity_2m"] ?? "?")%, wind \(c["wind_speed_10m"] ?? "?") km/h, \(wmo(c["weather_code"] as? Int ?? -1))."
        let days = d["time"] as? [String] ?? []
        for (i, day) in days.enumerated() {
            let mx = (d["temperature_2m_max"] as? [Any])?[i] ?? "?", mn = (d["temperature_2m_min"] as? [Any])?[i] ?? "?"
            let pp = (d["precipitation_probability_max"] as? [Any])?[i] ?? "?", wc = (d["weather_code"] as? [Int])?[i] ?? -1
            out += "\n\(day): \(mn)–\(mx)°C, rain \(pp)%, \(wmo(wc))"
        }
        return out
    }
    static func wmo(_ c: Int) -> String {
        switch c { case 0: "clear"; case 1, 2: "partly cloudy"; case 3: "overcast"; case 45, 48: "fog"; case 51...57: "drizzle"; case 61...67: "rain"; case 71...77: "snow"; case 80...82: "showers"; case 95...99: "thunderstorm"; default: "—" }
    }
    static func err(_ m: String) -> NSError { NSError(domain: "Vortex", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
}

// MARK: - UI

struct PluginsView: View {
    @StateObject var ps = PluginStore.shared
    @Local var makerText = ""
    @Local var making = false
    @Local var draft: PluginManifest?
    @Local var iconImg: NSImage?
    @Local var iconData: String?
    @Local var iconNote = ""
    @Local var editing: String?
    @Local var eName = ""
    @Local var eVer = ""
    @Local var eDesc = ""
    @Local var eIcon: String?
    @AppStorage("chatTools", store: AccountProfile.preferences) var chatTools = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Plugins").font(.largeTitle.bold()); Spacer()
                    Toggle("Use tools in chat", isOn: $chatTools)
                    Button("Open Plugin Store") { ModelBrowserServer.shared.open(page: "plugins") }
                    Button("Import plugin.json…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
                        p.begin { if $0 == .OK, let u = p.url { Task { @MainActor in PluginStore.shared.importFile(u) } } }
                    }
                }
                Text("Plugins give models tools. Enabled plugins are offered to the model in chat; it decides when to call them. Models with native tool calling (e.g. qwen2.5) use it directly; others use a text protocol.").font(.callout).foregroundStyle(.secondary)
                if !ps.message.isEmpty { Text(ps.message).font(.callout).foregroundStyle(ps.message.contains("fail") ? .red : .green) }
                GroupBox("Installed") {
                    ForEach(ps.installed) { p in
                        HStack(alignment: .top) {
                            Image(systemName: p.icon).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).bold() + Text("  v\(p.version) · \(p.author)").font(.caption).foregroundColor(.secondary)
                                Text(p.description).font(.caption).foregroundStyle(.secondary)
                                Text(p.tools.map { "\($0.name) (\($0.kind))" }.joined(separator: " · ")).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ModePicker(mode: Binding(get: { ps.mode(p.id) }, set: { ps.setMode(p.id, $0) }))
                            Button(role: .destructive) { ps.remove(p.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                        Divider()
                    }
                    if ps.installed.isEmpty { Text("No plugins yet. Open the Plugin Store.").foregroundStyle(.secondary) }
                }
                GroupBox("Plugin Maker — describe a plugin and Vortex writes it") {
                    VStack(alignment: .leading) {
                        TextField("e.g. Convert currencies using a free exchange-rate API", text: $makerText, axis: .vertical).lineLimit(2...4)
                        HStack {
                            Button(making ? "Generating…" : "Generate") {
                                making = true; ps.message = ""
                                Task { do { draft = try await ps.make(description: makerText) } catch { ps.message = "Maker failed: \(error.localizedDescription)" }; making = false }
                            }.disabled(makerText.isEmpty || making).buttonStyle(.borderedProminent)
                            Text("Uses the model in Settings → pluginMakerModel (default: vortex). Review the code before installing.").font(.caption).foregroundStyle(.secondary)
                        }
                        if let d = draft {
                            let enc: String = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return (try? e.encode(d)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }()
                            ScrollView { Text(enc).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 220)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                            HStack(spacing: 10) {
                                Image(nsImage: iconImg ?? StoreNet.defaultIcon()).resizable().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 10))
                                Text("Icon:").bold()
                                Button("Upload image…") {
                                    let p = NSOpenPanel(); p.allowedContentTypes = [.png, .jpeg, .image]
                                    p.begin { if $0 == .OK, let u = p.url, let i = NSImage(contentsOf: u), let f = StoreNet.fit256(i) { iconData = f.0; iconImg = NSImage(data: Data(base64Encoded: String(f.0.dropFirst(22))) ?? Data()); iconNote = f.1 } }
                                }
                                Button("Generate with AI") { iconNote = "Generating…"; Task { do { let i = try await ps.genIcon(d.description); if let f = StoreNet.fit256(i) { iconData = f.0; iconImg = i; iconNote = "AI icon: " + f.1 } } catch { iconNote = "\(error.localizedDescription) — upload one or skip to use the red X." } } }
                                Button("Skip (red X)") { iconData = nil; iconImg = nil; iconNote = "Using the default red X." }
                                Text(iconNote).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Install") { do { try ps.install(d); draft = nil } catch { ps.message = "Install failed: \(error.localizedDescription)" } }.buttonStyle(.borderedProminent)
                                Button("Upload to store") { Task { await ps.uploadToStore(d, iconDataURL: iconData) } }
                                Button("Test first tool") {
                                    Task { do { let t = d.tools[0]; let r = try await PluginRunner.run(t, [:]); ps.message = "Test: \(r.prefix(200))" } catch { ps.message = "Test failed: \(error.localizedDescription)" } }
                                }
                                Button("Discard") { draft = nil }
                            }
                        }
                    }.padding(6)
                }
                GroupBox("My plugins" + (ps.myUser.isEmpty ? "" : " · \(ps.myUser)")) {
                    VStack(alignment: .leading) {
                        HStack { Button("Refresh") { Task { await ps.refreshMine() } }
                            Text(ps.myList.isEmpty ? "You have not published any plugins yet." : "\(ps.myList.count) published · \(ps.myList.reduce(0) { $0 + $1.installs }) total installs").font(.caption).foregroundStyle(.secondary) }
                        ForEach(ps.myList) { p in
                            HStack(alignment: .top) {
                                StoreIcon(p: p)
                                if editing == p.id {
                                    VStack(alignment: .leading) {
                                        TextField("Name", text: $eName); TextField("Version", text: $eVer); TextField("Description", text: $eDesc, axis: .vertical).lineLimit(2...4)
                                        HStack {
                                            Button("New icon…") { let o = NSOpenPanel(); o.allowedContentTypes = [.image]; o.begin { if $0 == .OK, let u = o.url, let i = NSImage(contentsOf: u) { eIcon = StoreNet.fit256(i)?.0 } } }
                                            if eIcon != nil { Text("icon ready (256×256)").font(.caption) }
                                            Button("Save") { var patch: [String: Any] = ["name": eName, "version": eVer, "description": eDesc]; if let i = eIcon { patch["icon"] = i }
                                                editing = nil; Task { await ps.editStore(p.id, patch) } }.buttonStyle(.borderedProminent)
                                            Button("Cancel") { editing = nil }
                                        }
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name).bold() + Text("  v\(p.version) · by \(p.author)").font(.caption).foregroundColor(.secondary)
                                        Text(p.description).font(.caption).foregroundStyle(.secondary)
                                        Text("\(p.installs) install\(p.installs == 1 ? "" : "s")").font(.caption2)
                                    }
                                    Spacer()
                                    Button("Edit") { editing = p.id; eName = p.name; eVer = p.version; eDesc = p.description; eIcon = nil }
                                    Button("Unpublish", role: .destructive) { Task { await ps.unpublish(p.id) } }
                                }
                            }
                            Divider()
                        }
                    }.padding(6)
                }
                GroupBox("Plugin Store") {
                    VStack(alignment: .leading) {
                        Button("Refresh store") { Task { await ps.refreshStore() } }
                        if ps.storeList.isEmpty { Text("No plugins in the store yet.").foregroundStyle(.secondary) }
                        ForEach(ps.storeList) { p in
                            HStack(alignment: .top) {
                                StoreIcon(p: p)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).bold() + Text("  v\(p.version) · by \(p.author)").font(.caption).foregroundColor(.secondary)
                                    Text(p.description).font(.caption).foregroundStyle(.secondary)
                                    Text("\(p.installs) install\(p.installs == 1 ? "" : "s")").font(.caption2)
                                }
                                Spacer()
                                Button(ps.installed.contains { $0.id == p.id } ? "Reinstall" : "Install") { Task { await ps.installFromStore(p.id) } }
                            }
                            Divider()
                        }
                    }.padding(6)
                }
            }.padding(20)
        }
        .task { await ps.refreshStore(); if !(Keychain.get(account: "redx-session") ?? "").isEmpty { await ps.refreshMine() } }
        .sheet(isPresented: Binding(get: { ps.needSignIn }, set: { if !$0 && ps.needSignIn { ps.signInFinished(false) } })) {
            RedXSignInSheet { ok in ps.signInFinished(ok) }
        }
    }
}

struct StoreIcon: View {
    let p: StorePlugin
    @Local var img: NSImage?
    var body: some View {
        Image(nsImage: img ?? StoreNet.defaultIcon()).resizable().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: p.updated) {
                guard let u = StoreNet.iconURL(p), let r = try? await VultrTLS.session.data(from: u), let i = NSImage(data: r.0) else { return }
                img = i
            }
    }
}
