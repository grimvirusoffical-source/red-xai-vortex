import Foundation
import SwiftUI
import Metal

/// Optional compute sharing: this Mac runs a Metal llama.cpp RPC worker on 127.0.0.1, an SSH reverse tunnel exposes it
/// only on the server's loopback, and `dolphin-pool on|off` restarts llama-server with or without `--rpc`. Off by default.
@MainActor
final class NodeManager: ObservableObject {
    static let shared = NodeManager()
    @Published var sharing = false
    @Published var busy = false
    @Published var status = "Off"
    @Published var serverPool = "unknown"
    private var worker: Process?
    private var tunnel: Process?
    let port = 50052

    nonisolated var host: String { UserDefaults.standard.string(forKey: "sshHost") ?? Defaults.sshHost }
    nonisolated var key: String { ((UserDefaults.standard.string(forKey: "sshKey") ?? "~/.ssh/id_ed25519") as NSString).expandingTildeInPath }
    var workerBinary: String? { Bundle.main.url(forResource: "ggml-rpc-server", withExtension: nil)?.path }

    static func caps() -> (cpu: String, cores: Int, gpu: String, ramGB: Int64, vramGB: Double) {
        var size = 0; sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var b = [CChar](repeating: 0, count: max(size, 1)); sysctlbyname("machdep.cpu.brand_string", &b, &size, nil, 0)
        let dev = MTLCreateSystemDefaultDevice()
        return (String(cString: b), ProcessInfo.processInfo.activeProcessorCount, dev?.name ?? "—",
                Int64(ProcessInfo.processInfo.physicalMemory / 1_073_741_824), Double(dev?.recommendedMaxWorkingSetSize ?? 0) / 1_073_741_824)
    }

    @discardableResult
    nonisolated static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
    }
    nonisolated func remote(_ cmd: String) async -> (Int32, String) {
        let h = host, k = key
        return await Task.detached { Self.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-i", k, h, cmd]) }.value
    }

    func refresh() async {
        let r = await remote("dolphin-pool status")
        serverPool = r.0 == 0 ? (r.1.contains("pool=on") ? "on" : "off") : "unreachable"
    }

    func setSharing(_ on: Bool) async {
        busy = true; defer { busy = false }
        if on { await start() } else { await stop() }
        await refresh()
    }

    private func start() async {
        guard let bin = workerBinary else { status = "Worker binary missing from the app"; sharing = false; return }
        killLocal()
        let w = Process(); w.executableURL = URL(fileURLWithPath: bin)
        w.arguments = ["-H", "127.0.0.1", "-p", "\(port)"]
        w.standardOutput = FileHandle.nullDevice; w.standardError = FileHandle.nullDevice
        do { try w.run(); worker = w } catch { status = "Worker failed: \(error.localizedDescription)"; sharing = false; return }
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        t.arguments = ["-N", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ExitOnForwardFailure=yes",
                       "-i", key, "-R", "127.0.0.1:\(port):127.0.0.1:\(port)", host]
        t.standardError = FileHandle.nullDevice
        do { try t.run(); tunnel = t } catch { status = "Tunnel failed"; killLocal(); sharing = false; return }
        status = "Connecting…"
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let r = await remote("dolphin-pool on")
        if r.0 == 0 { sharing = true; status = "Sharing this Mac's CPU/GPU with the server" }
        else { status = "Server could not pool: \(r.1.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))"; killLocal(); sharing = false }
    }

    private func stop() async {
        _ = await remote("dolphin-pool off")
        killLocal(); sharing = false; status = "Off"
    }

    func killLocal() {
        for p in [tunnel, worker] { if p?.isRunning == true { p?.terminate() } }
        tunnel = nil; worker = nil
        Self.run("/usr/bin/pkill", ["-f", "Vortex.app/Contents/Resources/ggml-rpc-server"])
    }

    /// Quit: never leave the worker running; tell the server to stop pooling.
    func shutdown() {
        guard sharing || worker != nil else { return }
        killLocal()
        Self.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-i", key, host, "dolphin-pool off"])
        sharing = false
    }
}

struct NodeSettings: View {
    @ObservedObject var node = NodeManager.shared
    var body: some View {
        Form {
            Section("This Mac") {
                let c = NodeManager.caps()
                LabeledContent("CPU", value: "\(c.cpu) · \(c.cores) cores")
                LabeledContent("GPU", value: c.gpu)
                LabeledContent("RAM / GPU memory", value: "\(c.ramGB) GB / \(String(format: "%.1f", c.vramGB)) GB")
            }
            Section("Compute sharing") {
                Toggle("Share this Mac's CPU/GPU", isOn: Binding(get: { node.sharing }, set: { v in Task { await node.setSharing(v) } }))
                    .disabled(node.busy)
                HStack {
                    Circle().fill(node.sharing ? .green : .gray).frame(width: 9, height: 9)
                    Text(node.status)
                    if node.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("Server pool: \(node.serverPool)").foregroundStyle(.secondary)
                }
                Text("Off by default and turned off when Red-XAI Vortex quits. When on, a Metal worker runs on this Mac (127.0.0.1 only) and an SSH reverse tunnel lets the server use it; the server restarts its model with --rpc, so the first reply after switching is slower. Over home internet this is usually slower than the server alone — use it to test.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .task { await node.refresh() }
    }
}
