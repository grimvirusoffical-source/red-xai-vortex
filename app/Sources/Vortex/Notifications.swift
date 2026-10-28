import SwiftUI
import UserNotifications

struct VXNotification: Codable, Identifiable, Equatable {
    var id: String
    var kind: String
    var title: String
    var body: String?
    var link: String?
    var ts: Int64
    var read: Bool
}

/// Server notifications feed (/v1/notifications): Cloud PC requests and decisions,
/// agent replies, finished media/merge/distill jobs, updates, plugin uploads.
@MainActor final class NotificationStore: ObservableObject {
    static let shared = NotificationStore()
    @Published var items: [VXNotification] = []
    @Published var unread = 0
    @Published var error = ""
    private var seen = Set<String>()
    private var primed = false
    private var timer: Timer?

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { _ in Task { @MainActor in await NotificationStore.shared.refresh() } }
        Task { await refresh() }
    }

    private func req(_ path: String, _ method: String = "GET", _ body: [String: Any]? = nil) async throws -> Data {
        let base = AccountProfile.preferences.string(forKey: "serverURL") ?? Defaults.serverURL
        var r = URLRequest(url: API.url(base, path)!, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("Bearer \(Keychain.get() ?? "")", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let b = body { r.httpBody = try JSONSerialization.data(withJSONObject: b) }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw NSError(domain: "notifications", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"]) }
        return d
    }

    func refresh() async {
        struct L: Codable { var unread: Int; var data: [VXNotification] }
        do {
            let l = try JSONDecoder().decode(L.self, from: try await req("/notifications"))
            items = l.data; unread = l.unread; error = ""
            for n in l.data where !n.read && !seen.contains(n.id) {
                seen.insert(n.id)
                if primed { post(n) }
            }
            primed = true
            NSApp?.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
        } catch { self.error = error.localizedDescription }
    }

    private func post(_ n: VXNotification) {
        let c = UNMutableNotificationContent()
        c.title = n.title; c.body = n.body ?? ""; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: n.id, content: c, trigger: nil))
    }

    func markRead(_ ids: [String]? = nil) async {
        let body: [String: Any] = ids == nil ? ["all": true] : ["ids": ids!]
        _ = try? await req("/notifications/read", "POST", body)
        await refresh()
    }
}

struct NotificationsView: View {
    @ObservedObject var store = NotificationStore.shared
    static let icons = ["cloudpc_request": "desktopcomputer", "cloudpc_decision": "checkmark.shield", "agent": "person.3",
                        "media": "film", "merge": "arrow.triangle.merge", "distill": "graduationcap", "update": "arrow.down.circle", "plugin": "puzzlepiece"]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notifications").font(.title2.bold())
                if store.unread > 0 { Text("\(store.unread) unread").foregroundStyle(.secondary) }
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }
                Button("Mark all read") { Task { await store.markRead() } }.disabled(store.unread == 0)
            }
            if !store.error.isEmpty { Text(store.error).foregroundStyle(.red).font(.caption) }
            if store.items.isEmpty {
                Text("No notifications yet. Cloud PC requests, agent replies, finished media and merges, and updates show up here.")
                    .foregroundStyle(.secondary).padding(.top, 20)
            }
            List(store.items) { n in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Self.icons[n.kind] ?? "bell").frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.title).fontWeight(n.read ? .regular : .semibold)
                        if let b = n.body, !b.isEmpty { Text(b).font(.callout).foregroundStyle(.secondary).lineLimit(4) }
                        Text(Date(timeIntervalSince1970: TimeInterval(n.ts)), style: .relative).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if !n.read { Button("Mark read") { Task { await store.markRead([n.id]) } }.buttonStyle(.borderless) }
                }.opacity(n.read ? 0.7 : 1)
            }
        }.padding().task { await store.refresh() }
    }
}
