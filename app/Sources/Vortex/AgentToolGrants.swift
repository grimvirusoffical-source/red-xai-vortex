import Foundation

/// Maps a configured agent grant to one existing tool category. This cannot
/// turn on a machine permission or bypass the global PC emergency stop.
enum AgentToolGrants {
    static func permits(_ t: ToolSpec, _ a: AgentProfile?) -> Bool {
        guard let a else { return true }
        if let kind = PCKind(source: t.source) {
            guard a.pcControlOn else { return false }
            guard let permissions = a.permissions else { return true }
            let category: String
            switch kind {
            case .filesRead: category = "files-read"
            case .filesWrite: category = "files-write"
            case .shell: category = "shell"
            case .apps: category = "apps"
            case .input: category = "input"
            case .screenshot: category = "screen"
            case .browser: category = "browser"
            case .clipboard: category = "clipboard"
            }
            return permissions.contains(category)
        }
        return a.toolsOn && (a.permissions == nil || a.permissions?.contains("plugins") == true)
    }
}
