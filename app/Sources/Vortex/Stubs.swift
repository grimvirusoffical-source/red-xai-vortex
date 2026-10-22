import Foundation
// Placeholders filled in by later builds (MCP, PC control, skills).
@MainActor final class MCPStore { static let shared = MCPStore(); func enabledTools() -> [ToolSpec] { [] } }
@MainActor final class SkillStore { static let shared = SkillStore(); func activeExtraTools(all: [ToolSpec]) -> [ToolSpec] { [] } }
@MainActor final class PCControl {
    static let shared = PCControl()
    func tools(for model: String) -> [ToolSpec] { [] }
    nonisolated static func logAction(_ s: String) {}
}
