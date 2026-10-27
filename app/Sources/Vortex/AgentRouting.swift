import Foundation

/// Native Mac agent model selection: use the user's authenticated model
/// listing only, never substitute a model they cannot access.
enum AgentModelRouter {
    static func needsBrowserAutomation(_ task: String) -> Bool {
        let text = task.lowercased()
        return ["discord", "chrome tab", "browser tab", "send a message", "dm a friend", "click the submit", "post to a chat"].contains(where: text.contains)
    }

    static func genre(_ task: String) -> String {
        let t = task.lowercased()
        if ["code", "python", "typescript", "javascript", "repository", "github", "debug", "compile", "programming", "test suite"].contains(where: t.contains) { return "code" }
        if ["prove", "logic", "reason", "analy", "research", "calculate", "math", "compare"].contains(where: t.contains) { return "reason" }
        if ["story", "novel", "poetry", "roleplay", "creative", "lyrics"].contains(where: t.contains) { return "write" }
        if ["image", "photo", "screenshot", "picture"].contains(where: t.contains) { return "vision" }
        return "general"
    }
    static let candidates: [String: [String]] = [
        "code": ["qwen2.5-coder-32b", "vortex-pro", "qwen2.5-coder-14b", "vortex-std", "vortex"],
        "reason": ["r1-distill-qwen-32b", "qwq-32b", "r1-distill-qwen-14b", "vortex-pro", "vortex"],
        "write": ["mistral-small-24b", "dolphin3-mistral-24b-q6k", "vortex"],
        "vision": ["gemma3-12b-vision", "qwen2.5-vl-7b", "vortex"],
        "general": ["vortex", "red-xai", "vortex-std", "vortex-mini"]
    ]
    static func select(task: String, profile: AgentProfile, available: [String]) -> (executor: String, planner: String?) {
        guard profile.provider == "vortex", let mode = profile.modelMode, mode != "single" else {
            return (profile.model, nil)
        }
        var permitted = Set(available)
        if let pool = profile.modelPool, !pool.isEmpty { permitted.formIntersection(pool) }
        func first(_ list: [String]) -> String? { list.first(where: permitted.contains) }
        let pick = first(candidates[genre(task)] ?? []) ??
            first(candidates["general"] ?? []) ??
            available.first(where: permitted.contains) ??
            profile.model
        let plan: String?
        if mode == "mix" {
            plan = ((candidates["reason"] ?? []) + (candidates["code"] ?? []) + (candidates["general"] ?? [])).first {
                permitted.contains($0) && $0 != pick
            }
        } else { plan = nil }
        return (pick, plan)
    }
}
