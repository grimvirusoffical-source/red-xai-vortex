import Foundation
import SwiftUI

/// Native Mac agent scheduler. GUI tools belong to this Mac, so local work
/// runs only while Vortex is open and signed in. Server agents run separately.
@MainActor final class LocalAgentScheduler: ObservableObject {
    static let shared = LocalAgentScheduler()
    @Published private(set) var activeIDs: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var timer: Timer?

    var stopped: Bool { UserDefaults.standard.bool(forKey: "agents.emergencyStop") }

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { await LocalAgentScheduler.shared.tick() }
        }
        Task { await tick() }
    }

    func tick() async {
        guard !stopped && !PCControl.shared.killed && AccountGate.shared.ready else { return }
        for a in AgentStore.shared.agents {
            guard (a.runOn ?? "local") == "local", a.running == true, !activeIDs.contains(a.id),
                  let period = a.scheduleSeconds, period >= 15,
                  let goal = a.goal, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let minimum = a.nonstop == true ? 15.0 : Double(period)
            guard a.lastRun.map({ Date().timeIntervalSince($0) >= minimum }) ?? true else { continue }
            launch(a)
        }
    }

    func launch(_ a: AgentProfile) {
        guard !stopped && !PCControl.shared.killed && AccountGate.shared.ready else {
            AgentStore.shared.message = "Agent stopped. Sign in or reset the PC kill switch before running."
            return
        }
        guard !activeIDs.contains(a.id) else { return }
        activeIDs.insert(a.id)
        if let i = AgentStore.shared.agents.firstIndex(where: { $0.id == a.id }) {
            AgentStore.shared.agents[i].lastRun = Date()
            AgentStore.shared.save()
        }
        tasks[a.id] = Task { [weak self] in
            await self?.execute(a)
            self?.activeIDs.remove(a.id)
            self?.tasks[a.id] = nil
        }
    }

    private func execute(_ a: AgentProfile) async {
        let goal = (a.goal ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            AgentStore.shared.message = "Give the agent a concrete task before running it."
            return
        }
        let base = UserDefaults.standard.string(forKey: "serverURL") ?? Defaults.serverURL
        let gatewayKey = Keychain.get() ?? ""
        let available = (try? await API.models(base: base, key: gatewayKey)) ?? []
        let selected = AgentModelRouter.select(task: goal, profile: a, available: available)
        var p = ChatParams(baseURL: base, apiKey: gatewayKey, model: selected.executor,
                           temperature: 0.4, topP: 0.95, repeatPenalty: 1.0,
                           topK: 40, maxTokens: 1500, seed: -1)
        p = AgentStore.shared.chatParams(for: a.id, fallback: p)
        // The selected model must not be overwritten by an old "auto" profile.
        if a.provider == "vortex" { p.model = selected.executor }
        let tools = ToolRegistry.tools(for: p.model, agent: a)
        var instructions = a.systemPrompt
        if let planner = selected.planner, a.provider == "vortex" {
            var pp = p
            pp.model = planner
            let planMessages: [[String: Any]] = [
                ["role": "system", "content": "Plan the task concisely using only available capabilities. Do not execute tools or pretend results exist."],
                ["role": "user", "content": goal]
            ]
            if let response = try? await Agent.complete(pp, messages: planMessages, tools: []),
               let message = (response["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
               let plan = message["content"] as? String {
                instructions += "\n\nSecond-model plan (suggestions only, verify by tools):\n" + String(plan.prefix(3000))
            }
        }
        let history = [Message(role: "system", content: instructions), Message(role: "user", content: goal)]
        let who = ActivityAgent(id: a.id, name: a.name)
        do {
            let (result, _) = try await ActivityLog.$agent.withValue(who) {
                try await Agent.run(p, history: history, tools: tools,
                                    agentAlwaysAllow: a.alwaysAllow ?? false,
                                    onStep: { _ in })
            }
            ActivityLog.add("agent.result", summary: "Completed scheduled task: " + String(result.prefix(260)),
                            detail: result, agent: who)
            AgentStore.shared.message = a.name + ": " + String(result.prefix(250))
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "DONE",
               let i = AgentStore.shared.agents.firstIndex(where: { $0.id == a.id }) {
                AgentStore.shared.agents[i].running = false
                AgentStore.shared.save()
            }
        } catch is CancellationError {
            ActivityLog.add("agent.stop", summary: "Scheduled agent stopped.", agent: who)
        } catch {
            ActivityLog.add("agent.error", summary: error.localizedDescription, agent: who)
            AgentStore.shared.message = a.name + ": " + error.localizedDescription
        }
    }

    func stopAll() {
        UserDefaults.standard.set(true, forKey: "agents.emergencyStop")
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        activeIDs.removeAll()
        for i in AgentStore.shared.agents.indices {
            AgentStore.shared.agents[i].running = false
            AgentStore.shared.agents[i].alwaysAllow = false
        }
        AgentStore.shared.save()
        PCControl.shared.kill() // interrupts PC actions and revokes unattended control
        Task {
            await BGAgentStore.shared.refresh()
            for a in BGAgentStore.shared.agents where a.on { await BGAgentStore.shared.toggle(a, false) }
        }
    }

    func resetStop() {
        UserDefaults.standard.set(false, forKey: "agents.emergencyStop")
        if PCControl.shared.killed { PCControl.shared.resume() }
        AgentStore.shared.message = "Emergency stop reset. All agents remain paused until you enable them."
    }
}
