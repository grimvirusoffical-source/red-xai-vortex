import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Append-only, searchable, exportable agent activity log (same JSONL format as the Windows/Linux app).
/// One JSON object per line in ~/Library/Application Support/Red-XAI Vortex/activity/YYYY-MM.jsonl (0600).
struct ActivityEvent: Codable, Identifiable, Hashable {
    var ts: Date
    var seq: Int64
    var runID: String?
    var agentID: String
    var agent: String
    var kind: String          // run.start, tool.call, tool.result, approval.request/allow/deny, run.end, error, chat
    var tool: String?
    var summary: String
    var detail: String?
    var device: String?
    var id: String { "\(seq)-\(agentID)" }
}

struct ActivityAgent: Sendable { var id: String; var name: String }

enum ActivityLog {
    @TaskLocal static var agent = ActivityAgent(id: "vortex-default", name: "Vortex")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seq = Int64(Date().timeIntervalSince1970 * 1_000_000)

    static var dir: URL {
        let d = PCControl.baseDir.appendingPathComponent("activity")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d
    }
    static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .custom { c in
        let s = try c.singleValueContainer().decode(String.self)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "date"))
    }; return d }()

    /// Masks keys, tokens and passwords before anything is written.
    static func redact(_ s: String) -> String {
        var s = s
        let rules: [(String, String)] = [
            (#"(?i)(bearer\s+)[A-Za-z0-9._\-]{8,}"#, "$1••••"),
            (#"\b(sk|pk|rk|xai|gh[pousr]|xox[abpr]|AKIA)[-_A-Za-z0-9]{12,}"#, "••••"),
            (#"(?i)((?:password|passwd|secret|token|api[_-]?key|authorization)["']?\s*[:=]\s*["']?)[^\s"',}]+"#, "$1••••"),
            (#"\b[A-Fa-f0-9]{40,}\b"#, "••••"),
            (#"\b[A-Za-z0-9+/_\-]{48,}={0,2}"#, "••••")]
        for (p, r) in rules { s = s.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return s
    }
    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

    static func add(_ kind: String, tool: String? = nil, summary: String, detail: String? = nil, runID: String? = nil, agent a: ActivityAgent? = nil) {
        let who = a ?? agent
        lock.lock(); defer { lock.unlock() }
        seq += 1
        let e = ActivityEvent(ts: Date(), seq: seq, runID: runID, agentID: who.id, agent: who.name, kind: kind, tool: tool,
                              summary: clip(redact(summary), 400), detail: detail.map { clip(redact($0), 8000) },
                              device: Host.current().localizedName)
        guard var line = try? enc.encode(e) else { return }
        line.append(0x0A)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"
        let u = dir.appendingPathComponent(f.string(from: e.ts) + ".jsonl")
        if !FileManager.default.fileExists(atPath: u.path) {
            FileManager.default.createFile(atPath: u.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .activityChanged, object: nil) }
    }

    /// Newest first.
    static func search(agentID: String = "", kind: String = "", q: String = "", limit: Int = 500) -> [ActivityEvent] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        let ql = q.lowercased()
        var out: [ActivityEvent] = []
        for f in files {
            guard let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let evs = s.split(separator: "\n").compactMap { try? dec.decode(ActivityEvent.self, from: Data($0.utf8)) }.filter { e in
                (agentID.isEmpty || e.agentID == agentID) && (kind.isEmpty || e.kind.hasPrefix(kind)) &&
                (ql.isEmpty || "\(e.agent) \(e.kind) \(e.tool ?? "") \(e.summary) \(e.detail ?? "")".lowercased().contains(ql))
            }
            for e in evs.reversed() { out.append(e); if out.count >= limit { return out } }
        }
        return out
    }

    struct Stat: Identifiable { var id: String; var agent: String; var runs = 0, actions = 0, denied = 0, errors = 0; var last = Date.distantPast; var lastWhat = "" }
    static func stats() -> [Stat] {
        var m: [String: Stat] = [:]
        for e in search(limit: .max).reversed() {
            var s = m[e.agentID] ?? Stat(id: e.agentID, agent: e.agent)
            s.agent = e.agent
            switch e.kind { case "run.start": s.runs += 1; case "tool.call": s.actions += 1; case "approval.deny": s.denied += 1; case "error": s.errors += 1; default: break }
            s.last = e.ts; s.lastWhat = e.summary
            m[e.agentID] = s
        }
        return m.values.sorted { $0.last > $1.last }
    }

    static func export(_ evs: [ActivityEvent], csv: Bool) -> Data {
        let list = Array(evs.reversed())
        if !csv { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return (try? e.encode(list)) ?? Data() }
        func q(_ s: String?) -> String { "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let f = ISO8601DateFormatter()
        var out = "time,agent,run,kind,tool,summary,detail,device\n"
        for e in list { out += [f.string(from: e.ts), e.agent, e.runID ?? "", e.kind, e.tool ?? "", e.summary, e.detail ?? "", e.device ?? ""].map(q).joined(separator: ",") + "\n" }
        return Data(out.utf8)
    }
}

extension Notification.Name { static let activityChanged = Notification.Name("vortex.activityChanged") }

/// Global dashboard + per-agent activity view.
struct ActivityView: View {
    @StateObject var agents = AgentStore.shared
    @Local var agentID = ""
    @Local var kind = ""
    @Local var q = ""
    @Local var events: [ActivityEvent] = []
    @Local var stats: [ActivityLog.Stat] = []
    @Local var msg = ""
    @Environment(\.dismiss) var dismiss
    let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, h:mm:ss a"; return f }()

    func reload() {
        let (a, k, qq) = (agentID, kind, q)
        Task.detached {
            let e = ActivityLog.search(agentID: a, kind: k, q: qq, limit: 400), s = ActivityLog.stats()
            await MainActor.run { events = e; stats = s }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Activity").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }
            GroupBox("Dashboard") {
                if stats.isEmpty { Text("No activity yet. Agents log every action here.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        GridRow { Text("Agent").bold(); Text("Runs").bold(); Text("Actions").bold(); Text("Denied").bold(); Text("Errors").bold(); Text("Last activity").bold() }
                        ForEach(stats) { s in
                            GridRow {
                                Button(s.agent) { agentID = s.id; reload() }.buttonStyle(.link)
                                Text("\(s.runs)"); Text("\(s.actions)"); Text("\(s.denied)"); Text("\(s.errors)")
                                Text(df.string(from: s.last) + " · " + s.lastWhat).lineLimit(1).foregroundStyle(.secondary)
                            }
                        }
                    }.font(.callout)
                }
            }
            HStack {
                Picker("", selection: $agentID) {
                    Text("All agents").tag("")
                    Text("Vortex").tag("vortex-default")
                    ForEach(agents.agents) { a in Text(a.name).tag(a.id) }
                }.frame(width: 170)
                Picker("", selection: $kind) {
                    Text("Everything").tag(""); Text("Runs").tag("run"); Text("Actions").tag("tool"); Text("Approvals").tag("approval"); Text("Chat replies").tag("chat"); Text("Errors").tag("error")
                }.frame(width: 140)
                TextField("Search the log…", text: $q).textFieldStyle(.roundedBorder)
                Button("Export JSON") { save(csv: false) }
                Button("Export CSV") { save(csv: true) }
            }
            if !msg.isEmpty { Text(msg).font(.caption).foregroundStyle(.green) }
            List(events) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(df.string(from: e.ts)).foregroundStyle(.secondary); Text(e.agent).bold(); Text(e.kind).font(.caption).padding(.horizontal, 5).background(.quaternary, in: Capsule()); Text(e.summary).lineLimit(2) }
                    if let d = e.detail, d != e.summary, !d.isEmpty {
                        DisclosureGroup("details") { Text(d).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.font(.caption)
                    }
                }.font(.callout)
            }
            Text("The log is append-only and stays on this Mac. Keys, tokens and passwords are masked before anything is written.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(minWidth: 820, minHeight: 600)
        .onAppear(perform: reload)
        .onChange(of: agentID) { _ in reload() }
        .onChange(of: kind) { _ in reload() }
        .onChange(of: q) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .activityChanged)) { _ in reload() }
    }
    func save(csv: Bool) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "vortex-activity." + (csv ? "csv" : "json")
        p.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        guard p.runModal() == .OK, let u = p.url else { return }
        let all = ActivityLog.search(agentID: agentID, kind: kind, q: q, limit: .max)
        do { try ActivityLog.export(all, csv: csv).write(to: u); msg = "Saved \(all.count) entries to \(u.path)" } catch { msg = error.localizedDescription }
    }
}
