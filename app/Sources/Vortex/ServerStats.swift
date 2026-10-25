import SwiftUI

/// Live host stats from the gateway's /admin/system (sampled on every request, never cached).
/// Storage = disk space on "/". Bandwidth = network throughput right now (plus totals since boot).
@MainActor final class ServerStatsModel: ObservableObject {
    @Published var stats: [String: Any] = [:]
    @Published var error = ""
    @Published var updated: Date?
    private var task: Task<Void, Never>?
    func start(_ s: ServerDef) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetch(s)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    func stop() { task?.cancel() }
    func fetch(_ s: ServerDef) async {
        guard let u = URL(string: s.adminBase + "/admin/system") else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 6; r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("Bearer \(ServerStore.shared.key(for: s))", forHTTPHeaderField: "Authorization")
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { error = "HTTP \(code)"; return }
            stats = j; error = ""; updated = Date()
        } catch { self.error = "unreachable" }
    }
}

func fmtBytes(_ v: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .binary) }
func fmtRate(_ bps: Double) -> String {
    let bits = bps * 8
    if bits >= 1e9 { return String(format: "%.2f Gbit/s", bits / 1e9) }
    if bits >= 1e6 { return String(format: "%.1f Mbit/s", bits / 1e6) }
    return String(format: "%.0f kbit/s", bits / 1e3)
}

struct ServerStatsView: View {
    let server: ServerDef
    @StateObject var m = ServerStatsModel()
    private func d(_ k: String) -> [String: Any] { m.stats[k] as? [String: Any] ?? [:] }
    private func n(_ o: [String: Any], _ k: String) -> Double { (o[k] as? NSNumber)?.doubleValue ?? 0 }
    var body: some View {
        GroupBox("Live stats · \(server.name)") {
            if m.stats.isEmpty {
                Text(m.error.isEmpty ? "Loading…" : "Stats \(m.error)").font(.caption).foregroundStyle(.secondary)
            } else {
                let cpu = d("cpu"), mem = d("memory"), st = d("storage"), bw = d("bandwidth")
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("CPU").bold()
                        ProgressView(value: min(n(cpu, "percent"), 100), total: 100).frame(width: 160)
                        Text(String(format: "%.0f%% of %d cores · load %@", n(cpu, "percent"), Int(n(cpu, "cores")), ((cpu["load"] as? [String]) ?? []).joined(separator: " ")))
                    }
                    GridRow {
                        Text("RAM").bold()
                        ProgressView(value: n(mem, "used"), total: max(n(mem, "total"), 1)).frame(width: 160)
                        Text("\(fmtBytes(n(mem, "used"))) used of \(fmtBytes(n(mem, "total")))")
                    }
                    GridRow {
                        Text("Storage (disk)").bold()
                        ProgressView(value: n(st, "used"), total: max(n(st, "total"), 1)).frame(width: 160)
                        Text("\(fmtBytes(n(st, "used"))) used of \(fmtBytes(n(st, "total"))) · \(fmtBytes(n(st, "free"))) free")
                    }
                    GridRow {
                        Text("Bandwidth (network)").bold()
                        Text("↓ \(fmtRate(n(bw, "rx_bps")))  ↑ \(fmtRate(n(bw, "tx_bps")))").monospacedDigit()
                        Text("since boot ↓ \(fmtBytes(n(bw, "rx_total"))) ↑ \(fmtBytes(n(bw, "tx_total")))").foregroundStyle(.secondary)
                    }
                }.font(.caption)
                HStack {
                    Text(m.error.isEmpty ? "Live · refreshes every 3 s" : "Last update failed (\(m.error))").font(.caption2).foregroundStyle(m.error.isEmpty ? Color.secondary : Color.red)
                    if let u = m.updated { Text(u, style: .time).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .onAppear { m.start(server) }
        .onDisappear { m.stop() }
        .id(server.id)
    }
}
