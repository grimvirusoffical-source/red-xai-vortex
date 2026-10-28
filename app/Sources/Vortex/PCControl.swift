import SwiftUI
import AppKit
import Vision
import ApplicationServices

/// PC control: lets the Vortex / Red-XAI models act on this Mac through tools.
/// Every control type has its own switch, all OFF by default. Changes ask first unless the
/// local user explicitly enables Always allow. A persistent Stop indicator is shown in that mode,
/// and every action is written to pc-actions.log.
enum PCKind: String, CaseIterable, Identifiable {
    case filesRead, filesWrite, shell, apps, input, screenshot, browser, clipboard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .filesRead: "Read files & folders"; case .filesWrite: "Write, move & delete files"
        case .shell: "Run shell commands"; case .apps: "Open & quit apps"
        case .input: "Keyboard & mouse"; case .screenshot: "Screenshots (with text reading)"
        case .browser: "Browser (open pages, read current tab)"; case .clipboard: "Clipboard"
        }
    }
    var note: String {
        switch self {
        case .filesRead: "List folders and read text files."
        case .filesWrite: "Always asks before every write, move or delete. Deletes go to the Trash."
        case .shell: "Always asks before every command. 60 second limit."
        case .apps: "Opening is allowed; quitting an app always asks."
        case .input: "Typing, key presses and clicks always ask. Needs Accessibility permission."
        case .screenshot: "Needs Screen Recording permission. The model gets the text on screen."
        case .browser: "Opens links in your default browser; reads the front Safari/Chrome tab's title and URL."
        case .clipboard: "Reading is allowed; replacing the clipboard always asks."
        }
    }
    var key: String { "pc.\(rawValue)" }
    /// Types turned on by "Enable all safe": every action that changes something still asks first.
    static let safe: [PCKind] = [.filesRead, .filesWrite, .apps, .screenshot, .browser, .clipboard]
    init?(source: String) { guard source.hasPrefix("pc:") else { return nil }; self.init(rawValue: String(source.dropFirst(3))) }
}

@MainActor final class PCControl: ObservableObject {
    static let shared: PCControl = { PCTools.startWatching(); return PCControl() }()
    @Published var active = false
    @Published private(set) var alwaysAllow = PCAlwaysAllowGrant.allowed(killed: AccountProfile.preferences.bool(forKey: "pc.killed"), grantPresent: PCAlwaysAllowGrant.present())
    @Published private(set) var permissionError = ""
    @Published var killed = AccountProfile.preferences.bool(forKey: "pc.killed")
    /// Master switch (on by default). When on, vortex/red-xai always get the PC tools, no 🔧 needed;
    /// a type that is switched off makes the chat show a "Turn on …" button instead.
    @Published var enabled = AccountProfile.preferences.object(forKey: "pc.enabled") as? Bool ?? true
    nonisolated static let offMarker = "⚠️ PC off: "
    @Published var tick = 0
    private var hideWork: DispatchWorkItem?
    private var panel: NSPanel?

    nonisolated static func eligible(_ model: String) -> Bool {
        let m = (model.hasPrefix("local:") ? String(model.dropFirst(6)) : model).lowercased()
        return m == "vortex" || m == "red-xai" || m.hasPrefix("vortex-") || m.hasPrefix("red-xai")
    }
    func isOn(_ k: PCKind) -> Bool { AccountProfile.preferences.bool(forKey: k.key) }
    func set(_ k: PCKind, _ v: Bool) {
        AccountProfile.preferences.set(v, forKey: k.key); tick += 1
        if !v { PCExecutionState.shared.revoke(stopped: killed) }
        if v && k == .input { _ = Self.accessibility(prompt: true) }
        if v && k == .screenshot && !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        Self.logAction("setting \(k.rawValue) = \(v ? "ON" : "OFF")")
    }
    func setEnabled(_ v: Bool) {
        enabled = v; AccountProfile.preferences.set(v, forKey: "pc.enabled"); tick += 1
        if !v { setAlwaysAllow(false); PCExecutionState.shared.revoke(stopped: killed); hide() }
        else if alwaysAllow && !killed { flash() }
        Self.logAction("PC control master switch = \(v ? "ON" : "OFF")")
    }
    func setAlwaysAllow(_ value: Bool) {
        guard !value || !killed else { return }
        do { try PCAlwaysAllowGrant.set(value); permissionError = "" }
        catch { permissionError = "Could not save PC permission: " + error.localizedDescription; if value { return } }
        alwaysAllow = value; AccountProfile.preferences.set(value, forKey: "pc.alwaysAllow")
        if value { enable(PCKind.allCases); flash() }
        else { PCExecutionState.shared.revoke(stopped: killed); hide() }
        tick += 1
        Self.logAction("Always allow PC tools on this Mac = \(value ? "ON" : "OFF; per-action approvals restored")")
    }
    func needsApproval(for tool: ToolSpec) -> Bool {
        // Per-agent approval is an additional restriction: global Always allow
        // alone never grants automatic writes to a different agent.
        if tool.destructive && tool.source.hasPrefix("pc:") && AgentPermissionScope.alwaysAllow == false {
            return true
        }
        return PCApprovalPolicy.needsApproval(source: tool.source, destructive: tool.destructive,
            alwaysAllow: alwaysAllow, enabled: enabled, killed: killed,
            kindEnabled: PCKind(source: tool.source).map(isOn) ?? false)
    }
    func enable(_ kinds: [PCKind]) { if !enabled { setEnabled(true) }; for k in kinds where !isOn(k) { set(k, true) } }
    func kill() {
        killed = true; AccountProfile.preferences.set(true, forKey: "pc.killed")
        do { try PCAlwaysAllowGrant.set(false); permissionError = "" }
        catch { permissionError = "Control stopped. Could not remove the saved grant: " + error.localizedDescription }
        alwaysAllow = false; AccountProfile.preferences.set(false, forKey: "pc.alwaysAllow")
        PCExecutionState.shared.revoke(stopped: true)
        Confirm.cancelPCApproval()
        ChatStoreRef.store?.stop(); hide(); tick += 1
        Self.logAction("KILL SWITCH pressed: PC runs and child commands cancelled; unattended control revoked")
    }
    func resume() {
        setAlwaysAllow(false)
        guard !PCAlwaysAllowGrant.present() else {
            permissionError = "Control remains stopped because its saved permission could not be revoked."
            return
        }
        PCExecutionState.shared.resume(); killed = false; AccountProfile.preferences.set(false, forKey: "pc.killed")
        tick += 1; Self.logAction("kill switch reset; per-action approval mode")
    }

    func tools(for model: String) -> [ToolSpec] {
        guard AccountGate.shared.ready, enabled, !killed else { return [] }
        return PCKind.allCases.flatMap(PCTools.make)   // off types are offered too; Agent turns a call into a "Turn on" button
    }

    // MARK: indicator
    func flash() {
        active = true
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 44), styleMask: [.nonactivatingPanel, .hudWindow, .utilityWindow], backing: .buffered, defer: false)
            p.level = .statusBar; p.isFloatingPanel = true; p.worksWhenModal = true; p.hidesOnDeactivate = false; p.collectionBehavior = [.canJoinAllSpaces, .stationary]
            p.contentView = NSHostingView(rootView: PCIndicator())
            panel = p
        }
        if let s = NSScreen.main?.visibleFrame, let p = panel { p.setFrameOrigin(NSPoint(x: s.maxX - 266, y: s.maxY - 60)) }
        panel?.orderFrontRegardless()
        hideWork?.cancel()
        if alwaysAllow { return }
        let w = DispatchWorkItem { [weak self] in self?.hide() }; hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }
    func hide() { active = false; panel?.orderOut(nil) }

    // MARK: log
    nonisolated static var baseDir: URL { AccountProfile.directory }
    nonisolated static var logURL: URL { baseDir.appendingPathComponent("pc-actions.log") }
    nonisolated static func logAction(_ s: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + "  " + s.replacingOccurrences(of: "\n", with: " ") + "\n"
        let u = logURL
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: u, atomically: true, encoding: .utf8) }
    }
    nonisolated static func accessibility(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }
}

struct PCIndicator: View {
    @ObservedObject var pc = PCControl.shared
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 10, height: 10)
            Text(pc.alwaysAllow ? "PC control · always allowed" : "Vortex is controlling this Mac").font(.caption.bold())
            Spacer()
            Button("Stop") { PCControl.shared.kill() }.controlSize(.small)
        }.padding(.horizontal, 12).frame(width: 250, height: 44)
    }
}

enum PCError: LocalizedError {
    case msg(String)
    var errorDescription: String? { if case .msg(let s) = self { return s }; return nil }
}

/// The tools themselves. Each run re-checks the kill switch and its own toggle.
enum PCTools {
    static func obj(_ props: [String: String], _ req: [String]) -> [String: Any] {
        ["type": "object", "properties": props.mapValues { ["type": $0 == "number" ? "number" : "string"] }, "required": req]
    }
    static func path(_ a: [String: Any], _ k: String = "path") throws -> URL {
        guard let s = a[k] as? String, !s.isEmpty else { throw PCError.msg("missing \(k)") }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath).standardizedFileURL
    }
    static func guardOn(_ k: PCKind) async throws {
        try PCExecutionContext.check()
        let ok = await MainActor.run { () -> Bool in
            let c = PCControl.shared; guard AccountGate.shared.ready, c.enabled, !c.killed, c.isOn(k) else { return false }; c.flash(); return true
        }
        if !ok { throw PCError.msg("PC control for \(k.rawValue) is off or stopped") }
    }
    static func tool(_ k: PCKind, _ name: String, _ desc: String, _ schema: [String: Any], destructive: Bool = false, _ run: @escaping ([String: Any]) async throws -> String) -> ToolSpec {
        ToolSpec(name: name, description: desc, schema: schema, source: "pc:\(k.rawValue)", destructive: destructive) { a in try await guardOn(k); try PCExecutionContext.check(); return try await run(a) }
    }

    static func make(_ k: PCKind) -> [ToolSpec] {
        switch k {
        case .filesRead: return [
            tool(k, "pc_list_dir", "List a folder on this Mac (~ allowed).", obj(["path": "string"], ["path"])) { a in
                let u = try path(a); let items = try FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
                return items.prefix(300).map { i in let v = try? i.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]); return (v?.isDirectory == true ? "📁 " : "📄 ") + i.lastPathComponent + (v?.fileSize.map { " (\($0) B)" } ?? "") }.joined(separator: "\n")
            },
            tool(k, "pc_read_file", "Read a text file on this Mac (first 200 KB).", obj(["path": "string"], ["path"])) { a in
                let handle = try FileHandle(forReadingFrom: try path(a)); defer { try? handle.close() }; let d = try handle.read(upToCount: 200_000) ?? Data(); return String(decoding: d, as: UTF8.self)
            }]
        case .filesWrite: return [
            tool(k, "pc_write_file", "Create or overwrite a text file.", obj(["path": "string", "content": "string"], ["path", "content"]), destructive: true) { a in
                let u = try path(a); try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PCExecutionContext.check()
                try (a["content"] as? String ?? "").write(to: u, atomically: true, encoding: .utf8); return "wrote \(u.path)"
            },
            tool(k, "pc_move_file", "Move or rename a file or folder.", obj(["from": "string", "to": "string"], ["from", "to"]), destructive: true) { a in
                let f = try path(a, "from"), t = try path(a, "to"); try PCExecutionContext.check(); try FileManager.default.moveItem(at: f, to: t); return "moved to \(t.path)"
            },
            tool(k, "pc_delete_file", "Move a file or folder to the Trash.", obj(["path": "string"], ["path"]), destructive: true) { a in
                let u = try path(a); var out: NSURL?; try PCExecutionContext.check(); try FileManager.default.trashItem(at: u, resultingItemURL: &out); return "moved to Trash: \(u.path)"
            }]
        case .shell: return [
            tool(k, "pc_shell", "Run a zsh command on this Mac and return its output (60 s limit).", obj(["command": "string"], ["command"]), destructive: true) { a in
                guard let c = a["command"] as? String, !c.isEmpty else { throw PCError.msg("missing command") }
                return try await runProcess("/bin/zsh", ["-lc", c], timeout: 60)
            }]
        case .apps: return [
            tool(k, "pc_open_app", "Open (or bring forward) an app by name, e.g. Safari.", obj(["name": "string"], ["name"])) { a in
                guard let n = a["name"] as? String, !n.isEmpty else { throw PCError.msg("missing name") }
                if ["browser", "default browser", "web browser", "internet"].contains(n.lowercased()) { try await MainActor.run { try PCExecutionContext.check(); _ = NSWorkspace.shared.open(URL(string: "https://www.google.com")!) }; return "opened the default browser" }
                return try await runProcess("/usr/bin/open", ["-a", n], timeout: 20).isEmpty ? "opened \(n)" : "could not open \(n)"
            },
            tool(k, "pc_list_apps", "List running apps.", obj([:], [])) { _ in
                await MainActor.run { NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName).joined(separator: "\n") }
            },
            tool(k, "pc_quit_app", "Quit a running app by name.", obj(["name": "string"], ["name"]), destructive: true) { a in
                let n = (a["name"] as? String ?? "").lowercased()
                return try await MainActor.run {
                    try PCExecutionContext.check()
                    let apps = NSWorkspace.shared.runningApplications.filter { $0.localizedName?.lowercased() == n }
                    apps.forEach { $0.terminate() }; return apps.isEmpty ? "no app named \(n) is running" : "asked \(n) to quit"
                }
            }]
        case .input: return [
            tool(k, "pc_type_text", "Type text only into a verified, non-Vortex focused app. Browser typing requires the expected tab URL and refuses search/address fields.", obj(["text": "string", "expected_url": "string"], ["text"]), destructive: true) { a in
                try needAX(); let t = a["text"] as? String ?? ""; let target = try await targetApp(); try PCExecutionContext.check()
                // Browser inputs can easily land in a search box instead of the
                // intended app. Verify the active tab URL and focused AX element.
                if let target, let app = NSRunningApplication(processIdentifier: target),
                   ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac"].contains(app.bundleIdentifier ?? "") {
                    guard let expected = a["expected_url"] as? String, expected.count >= 4 else {
                        throw PCError.msg("Browser typing needs expected_url and a verified focused message editor. Nothing was typed.")
                    }
                    try await verifyBrowserTarget(app: app, expectedURL: expected)
                }
                try focusedInputIsNotSearchField(expectedPID: target)
                let units = Array(t.utf16); var offset = 0
                while offset < units.count {
                    try PCExecutionContext.check()
                    var end = min(offset + 20, units.count)
                    if end < units.count && (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
                    let chunk = Array(units[offset..<end])
                    for down in [true, false] { let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 0, keyDown: down); event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk); try PCTools.send(event, to: target) }
                    offset = end
                    try await Task.sleep(nanoseconds: 12_000_000)
                }
                return "typed \(t.count) characters"
            },
            tool(k, "pc_key", "Press a key or shortcut, e.g. \"cmd+s\", \"return\", \"cmd+shift+t\".", obj(["keys": "string"], ["keys"]), destructive: true) { a in
                try needAX(); let target = try await targetApp(); try PCExecutionContext.check(); let parts = (a["keys"] as? String ?? "").lowercased().split(separator: "+").map(String.init)
                var flags: CGEventFlags = []; var code: CGKeyCode?
                for p in parts { switch p {
                    case "cmd", "command": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift)
                    case "opt", "option", "alt": flags.insert(.maskAlternate); case "ctrl", "control": flags.insert(.maskControl)
                    default: code = keyCodes[p] } }
                guard let c = code else { throw PCError.msg("unknown key in \(parts.joined(separator: "+"))") }
                for down in [true, false] { let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: c, keyDown: down); e?.flags = flags; try PCTools.send(e, to: target) }
                return "pressed \(parts.joined(separator: "+"))"
            },
            tool(k, "pc_click", "Click at screen point x,y (top-left origin).", obj(["x": "number", "y": "number"], ["x", "y"]), destructive: true) { a in
                try needAX(); let p = CGPoint(x: (a["x"] as? NSNumber)?.doubleValue ?? 0, y: (a["y"] as? NSNumber)?.doubleValue ?? 0)
                for t in [CGEventType.leftMouseDown, .leftMouseUp] { try PCExecutionContext.check(); CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
                return "clicked \(Int(p.x)),\(Int(p.y))"
            }]
        case .screenshot: return [
            tool(k, "pc_screenshot", "Take a screenshot of the main screen and return the text visible on it.", obj([:], [])) { _ in
                guard CGPreflightScreenCaptureAccess() else { _ = await MainActor.run { CGRequestScreenCaptureAccess() }; throw PCError.msg("Screen Recording permission is needed (System Settings → Privacy & Security → Screen Recording)") }
                let f = PCControl.baseDir.appendingPathComponent("screenshots", isDirectory: true)
                try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
                let u = f.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970)).png")
                _ = try await runProcess("/usr/sbin/screencapture", ["-x", "-m", u.path], timeout: 20)
                guard let img = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw PCError.msg("screenshot failed") }
                let req = VNRecognizeTextRequest(); req.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: img).perform([req])
                let bounds = CGDisplayBounds(CGMainDisplayID())
                let text = (req.results ?? []).compactMap { item -> String? in
                    guard let value = item.topCandidates(1).first?.string else { return nil }
                    let x = bounds.minX + item.boundingBox.midX * bounds.width
                    let y = bounds.minY + (1 - item.boundingBox.midY) * bounds.height
                    return "[x:\(Int(x)), y:\(Int(y))] " + value
                }.joined(separator: "\n")
                return "Saved \(u.path) (\(img.width)x\(img.height)). Text on screen:\n" + (text.isEmpty ? "(none found)" : text)
            }]
        case .browser: return [
            tool(k, "pc_open_url", "Open a web page in the default browser.", obj(["url": "string"], ["url"])) { a in
                guard let s = a["url"] as? String, let u = URL(string: s), ["http", "https"].contains(u.scheme ?? "") else { throw PCError.msg("need an http(s) url") }
                try await MainActor.run { try PCExecutionContext.check(); _ = NSWorkspace.shared.open(u) }; return "opened \(s)"
            },
            tool(k, "pc_browser_tab", "Get the title and URL of the front tab in Safari or Chrome.", obj([:], [])) { _ in
                try await MainActor.run {
                    try PCExecutionContext.check()
                    for (app, s) in [("Safari", "tell application \"Safari\" to return (name of front document) & \" | \" & (URL of front document)"),
                                     ("Google Chrome", "tell application \"Google Chrome\" to return (title of active tab of front window) & \" | \" & (URL of active tab of front window)")]
                    where NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == app }) {
                        var err: NSDictionary?; if let r = NSAppleScript(source: s)?.executeAndReturnError(&err).stringValue { return "\(app): \(r)" }
                        if (err?[NSAppleScript.errorNumber] as? Int) == -1743 { return "error: macOS Automation permission for \(app) is off (System Settings → Privacy & Security → Automation → Red-XAI Vortex → \(app))" }
                    }
                    return "no Safari or Chrome tab available (or Automation permission was declined)"
                }
            }]
        case .clipboard: return [
            tool(k, "pc_clipboard_read", "Read the text on the clipboard.", obj([:], [])) { _ in
                try await MainActor.run { try PCExecutionContext.check(); return NSPasteboard.general.string(forType: .string) ?? "(clipboard has no text)" }
            },
            tool(k, "pc_clipboard_write", "Replace the clipboard with text.", obj(["text": "string"], ["text"]), destructive: true) { a in
                try await MainActor.run { try PCExecutionContext.check(); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a["text"] as? String ?? "", forType: .string) }; return "clipboard set"
            }]
        }
    }

    /// Deliver a synthetic key event straight to the frontmost app (more reliable than the HID tap).
    /// The last app other than Vortex that was frontmost (where "type hello" should go).
    nonisolated(unsafe) static var lastOther: NSRunningApplication?
    nonisolated(unsafe) static var watcher: NSObjectProtocol?
    static func startWatching() {
        guard watcher == nil else { return }
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != getpid() { lastOther = f }
        watcher = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a.processIdentifier != getpid() { lastOther = a }
        }
    }
    /// If Vortex itself is in front (the user just typed the request here), hand focus back to the app they were using.
    static func targetApp() async throws -> pid_t? {
        try PCExecutionContext.check()
        let (pid, activated) = try await MainActor.run { () throws -> (pid_t?, Bool) in
            try PCExecutionContext.check()
            if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != getpid() { return (f.processIdentifier, false) }
            guard let other = lastOther, !other.isTerminated,
                  other.processIdentifier != getpid() else {
                throw PCError.msg("No verified target app is selected. Focus the intended application and try again. Nothing was typed.")
            }
            other.activate(); return (other.processIdentifier, true)
        }
        if activated { try await Task.sleep(nanoseconds: 400_000_000) }
        try PCExecutionContext.check()
        return pid
    }
    static func send(_ e: CGEvent?, to target: pid_t?) throws {
        try PCExecutionContext.check()
        guard let e, let pid = target, pid != getpid() else {
            throw PCError.msg("Input target could not be verified. Refusing to type into Vortex.")
        }
        e.postToPid(pid)
    }

    static func verifyBrowserTarget(app: NSRunningApplication, expectedURL: String) async throws {
        guard let appName = app.localizedName, ["Google Chrome", "Safari", "Microsoft Edge"].contains(appName) else {
            throw PCError.msg("Unknown browser target.")
        }
        let script: String
        if appName == "Safari" { script = "tell application \"Safari\" to return URL of front document" }
        else { script = "tell application \"\(appName)\" to return URL of active tab of front window" }
        let address = await MainActor.run { () -> String in
            var err: NSDictionary?
            return NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue ?? ""
        }
        guard !address.isEmpty && address.lowercased().contains(expectedURL.lowercased()) else {
            throw PCError.msg("The active browser tab does not match the target URL. Nothing was typed.")
        }
    }

    static func focusedInputIsNotSearchField(expectedPID: pid_t?) throws {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else {
            throw PCError.msg("Could not verify the focused input. Nothing was typed.")
        }
        let ui = unsafeBitCast(element, to: AXUIElement.self)
        var focusedPID: pid_t = 0
        guard let expectedPID, expectedPID != getpid(),
              AXUIElementGetPid(ui, &focusedPID) == .success,
              focusedPID == expectedPID else {
            throw PCError.msg("The focused input belongs to a different application. Nothing was typed.")
        }
        var role: CFTypeRef?, title: CFTypeRef?, placeholder: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(ui, kAXRoleAttribute as CFString, &role)
        _ = AXUIElementCopyAttributeValue(ui, kAXTitleAttribute as CFString, &title)
        _ = AXUIElementCopyAttributeValue(ui, "AXPlaceholderValue" as CFString, &placeholder)
        let details = [title, placeholder].compactMap { $0 as? String }.joined(separator: " ").lowercased()
        if ["search", "address", "url", "location bar"].contains(where: { details.contains($0) }) {
            throw PCError.msg("The focused element looks like a search/address field, not the requested message editor. Nothing was typed.")
        }
    }
    static func needAX() throws {
        try PCExecutionContext.check()
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        try PCExecutionContext.check()
        if !PCControl.accessibility(prompt: true) || !CGPreflightPostEventAccess() { throw PCError.msg("Accessibility permission is needed (System Settings → Privacy & Security → Accessibility → Red-XAI Vortex)") }
        try PCExecutionContext.check()
    }

    static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = ["return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121]
        let letters: [(String, CGKeyCode)] = [("a",0),("s",1),("d",2),("f",3),("h",4),("g",5),("z",6),("x",7),("c",8),("v",9),("b",11),("q",12),("w",13),("e",14),("r",15),("y",16),("t",17),
            ("1",18),("2",19),("3",20),("4",21),("6",22),("5",23),("9",25),("7",26),("8",28),("0",29),("o",31),("u",32),("i",34),("p",35),("l",37),("j",38),("k",40),("n",45),("m",46)]
        for (k, v) in letters { m[k] = v }; return m
    }()

    static func runProcess(_ exe: String, _ args: [String], timeout: Double) async throws -> String {
        try PCExecutionContext.check()
        return try await PCCancellableProcess().run(exe, args, timeout: timeout, token: PCExecutionContext.token)
    }
}

/// Hub tab: switches, permissions, kill switch and the action log.
struct PCControlView: View {
    @ObservedObject var pc = PCControl.shared
    @Local var log = ""
    @Local var ax = false
    @Local var screen = false
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { _ = pc.tick; return pc.enabled }, set: { pc.setEnabled($0) })) {
                    VStack(alignment: .leading) { Text("PC Control").font(.headline); Text("When on, ask your selected model to use the computer tools on this Mac.").font(.caption).foregroundStyle(.secondary) }
                }
                Text("Each type below has its own switch. Changes ask Allow / Deny unless you explicitly turn on Always allow. Stop control cancels current PC runs and commands and restores approval mode.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if pc.killed {
                        Label("Stopped by the kill switch", systemImage: "hand.raised.fill").foregroundStyle(.red)
                        Spacer(); Button("Allow PC control again") { pc.resume() }
                    } else {
                        Label(pc.active ? "Acting now" : "Ready", systemImage: pc.active ? "record.circle" : "checkmark.circle").foregroundStyle(pc.active ? .red : .green)
                        Spacer(); Button("Stop everything (kill switch)", role: .destructive) { pc.kill() }
                    }
                }
            }
            Section("Approval mode") {
                Toggle("Always allow full PC control on this Mac", isOn: Binding(get: { pc.alwaysAllow }, set: { pc.setAlwaysAllow($0) }))
                    .disabled(pc.killed)
                Text("Enables all PC tool types and remembers your choice. Vortex can change files, run commands and control apps without asking each time. macOS permissions still apply. Stop control cancels active work; resetting Stop returns to per-action approvals.")
                    .font(.caption).foregroundStyle(.secondary)
                if !pc.permissionError.isEmpty { Text(pc.permissionError).foregroundStyle(.red).font(.caption) }
                if pc.alwaysAllow { Label("Always allowed · Stop remains visible above other windows", systemImage: "bolt.shield.fill").foregroundStyle(.orange) }
            }
            Section {
                HStack {
                    Button("Enable all safe") { pc.enable(PCKind.safe) }.help("Files, apps, screenshots, browser and clipboard. Changes still ask first.")
                    Button("Enable everything") { pc.enable(PCKind.allCases) }.help("Also shell commands and keyboard & mouse (each still asks first).")
                    Button("Turn all off") { for k in PCKind.allCases { pc.set(k, false) } }
                }
            }
            Section("What the model may do") {
                ForEach(PCKind.allCases) { k in
                    Toggle(isOn: Binding(get: { _ = pc.tick; return pc.isOn(k) }, set: { pc.set(k, $0) })) {
                        VStack(alignment: .leading) { Text(k.title); Text(pc.alwaysAllow ? "Allowed without per-action prompts while this type is on." : k.note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("macOS permissions") {
                HStack { Label("Accessibility (keyboard & mouse)", systemImage: ax ? "checkmark.seal.fill" : "exclamationmark.triangle"); Spacer()
                    Button("Request") { ax = PCControl.accessibility(prompt: true) }
                    Button("Open Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) } }
                HStack { Label("Screen Recording (screenshots)", systemImage: screen ? "checkmark.seal.fill" : "exclamationmark.triangle"); Spacer()
                    Button("Request") { screen = CGRequestScreenCaptureAccess() }
                    Button("Open Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) } }
                Button("Re-check") { refresh() }
            }
            Section("Action log") {
                ScrollView { Text(log.isEmpty ? "No actions yet." : log).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 180)
                HStack { Button("Refresh") { refresh() }; Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([PCControl.logURL]) }
                    Button("Clear") { try? "".write(to: PCControl.logURL, atomically: true, encoding: .utf8); log = "" } }
            }
        }.formStyle(.grouped).onAppear { refresh() }
    }
    func refresh() {
        ax = PCControl.accessibility(prompt: false); screen = CGPreflightScreenCaptureAccess()
        let u = PCControl.logURL
        Task.detached { let s = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            let tail = s.split(separator: "\n").suffix(200).reversed().joined(separator: "\n")
            await MainActor.run { log = tail } }
    }
}

/// Inline chat button shown when the model needed a PC control type that is off.
struct PCTurnOnButton: View {
    let kind: PCKind
    @ObservedObject var pc = PCControl.shared
    var body: some View {
        let on = { _ = pc.tick; return pc.isOn(kind) && pc.enabled }()
        Button { pc.enable([kind]) } label: {
            Label(on ? "\(kind.title): on — ask again" : "Turn on \(kind.title)", systemImage: on ? "checkmark.circle.fill" : "power")
        }.buttonStyle(.borderedProminent).tint(on ? .green : .red).controlSize(.small).disabled(on)
    }
}


/// Always available in the main window, including between tool actions.
struct PCControlStatusView: View {
    @ObservedObject var pc = PCControl.shared
    var body: some View {
        HStack(spacing: 7) {
            Menu {
                Toggle("PC control", isOn: Binding(get: { pc.enabled }, set: { pc.setEnabled($0) }))
                Toggle("Always allow on this Mac", isOn: Binding(get: { pc.alwaysAllow }, set: { pc.setAlwaysAllow($0) })).disabled(pc.killed)
                Text("Always allow enables every PC tool. macOS permissions still apply.")
                if pc.killed { Button("Reset Stop · ask each time") { pc.resume() } }
            } label: {
                Label(pc.killed ? "PC stopped" : !pc.enabled ? "PC off" : pc.alwaysAllow ? "Always allowed" : "Ask each time", systemImage: pc.killed ? "hand.raised.fill" : pc.alwaysAllow ? "bolt.shield.fill" : "desktopcomputer")
            }
            .help("PC control permissions and approval mode")
            if pc.enabled && !pc.killed {
                Button(role: .destructive) { pc.kill() } label: { Label("Stop control", systemImage: "stop.fill") }
                    .help("Cancel PC tasks and commands, and turn off Always allow")
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }.controlSize(.small)
        .onAppear { if pc.enabled && pc.alwaysAllow && !pc.killed { pc.flash() } }
    }
}
