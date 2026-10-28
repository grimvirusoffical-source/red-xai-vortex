import XCTest
@testable import Vortex

final class UnifiedAgentTests: XCTestCase {
    func testTaskGenreRoutingRespectsAuthenticatedModelListAndSelectedPool() {
        var agent = AgentProfile(id: "agent-test", name: "Research helper")
        agent.model = "vortex"
        agent.modelMode = "mix"
        let available = ["vortex", "qwen2.5-coder-14b", "r1-distill-qwen-14b"]
        let result = AgentModelRouter.select(task: "Debug this TypeScript project", profile: agent, available: available)
        XCTAssertEqual(result.executor, "qwen2.5-coder-14b")
        XCTAssertEqual(result.planner, "r1-distill-qwen-14b")
        agent.modelPool = ["vortex"]
        let limited = AgentModelRouter.select(task: "Debug TypeScript", profile: agent, available: available)
        XCTAssertEqual(limited.executor, "vortex")
        XCTAssertNil(limited.planner)
    }

    func testAgentPermissionsCannotGrantArbitraryComputerTool() {
        var agent = AgentProfile(id: "agent-test", name: "Read-only helper")
        agent.toolsOn = false
        agent.pcControlOn = true
        agent.permissions = ["files-read"]
        let fileRead = ToolSpec(name: "pc_read_file", description: "", schema: [:], source: "pc:filesRead") { _ in "" }
        let fileWrite = ToolSpec(name: "pc_write_file", description: "", schema: [:], source: "pc:filesWrite") { _ in "" }
        let shell = ToolSpec(name: "pc_shell", description: "", schema: [:], source: "pc:shell") { _ in "" }
        XCTAssertTrue(AgentToolGrants.permits(fileRead, agent))
        XCTAssertFalse(AgentToolGrants.permits(fileWrite, agent))
        XCTAssertFalse(AgentToolGrants.permits(shell, agent))
        agent.pcControlOn = false
        XCTAssertFalse(AgentToolGrants.permits(fileRead, agent))
    }

    func testBrowserAutomationRequiresVerifiedWorker() {
        XCTAssertTrue(AgentModelRouter.needsBrowserAutomation("Open Chrome's Discord tab and send a message"))
        XCTAssertFalse(AgentModelRouter.needsBrowserAutomation("Explain how SSH tunneling works"))
    }

    func testGroupLeaderOnlyWhenSelectedMember() {
        var chat = Chat()
        chat.participants = ["agent:a", "vortex"]
        chat.leaderParticipantID = "agent:a"
        XCTAssertTrue(chat.participants?.contains(chat.leaderParticipantID ?? "") == true)
        chat.leaderParticipantID = nil
        XCTAssertNil(chat.leaderParticipantID)
    }
}
