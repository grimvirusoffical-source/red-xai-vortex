import SwiftUI

enum PII {
    static let rules: [(String, String)] = [
        (#"\b(?:sk|pk|rk|redx_ai|redx_xai|ghp|github_pat|xox[abp]|AKIA)[-_A-Za-z0-9]{12,}\b"#, "[secret]"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),
        (#"\b(?:\d[ -]?){13,19}\b"#, "[number]"),
        (#"\b\d{1,3}(?:\.\d{1,3}){3}\b"#, "[ip]"),
        (#"\+?\d[\d\s().-]{8,}\d"#, "[phone]")]
    static func scrub(_ s: String) -> String {
        rules.reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression) }
    }
}

extension ChatStore {
    /// Training mode: send a rated (and optionally corrected) reply to Red-XAI's dataset. PII is scrubbed here and again on the server.
    func sendFeedback(messageID: UUID, rating: Int, correction: String?) {
        guard AccountProfile.preferences.bool(forKey: "trainingMode"), AccountProfile.preferences.bool(forKey: "trainingConsent") else { return }
        guard let c = chats.first(where: { $0.messages.contains { $0.id == messageID } }),
              let i = c.messages.firstIndex(where: { $0.id == messageID }) else { return }
        let ctx = c.messages[..<i].suffix(8).filter { $0.role != "system" && !$0.content.hasPrefix("⚠️") }
            .map { ["role": $0.role, "content": PII.scrub($0.content)] }
        var body: [String: Any] = ["consent": true, "rating": rating, "messages": ctx, "response": PII.scrub(c.messages[i].content),
                                   "model": AccountProfile.preferences.string(forKey: "model") ?? ""]
        if let correction, !correction.isEmpty { body["correction"] = PII.scrub(correction) }
        if let j = idx(c.id) { chats[j].messages[i].rating = rating; save() }
        Task { do { _ = try await Admin.call("POST", "/v1/redxai/feedback", body); status = "Thanks — saved for Vortex training" } catch { status = "Feedback failed: \(error.localizedDescription)" } }
    }
}

struct FeedbackBar: View {
    let message: Message
    @EnvironmentObject var store: ChatStore
    @AppStorage("trainingMode", store: AccountProfile.preferences) var trainingMode = false
    @Local var correcting = false
    @Local var text = ""
    var body: some View {
        if trainingMode && message.role == "assistant" && !message.content.isEmpty {
            HStack(spacing: 10) {
                Button { store.sendFeedback(messageID: message.id, rating: 1, correction: nil) } label: { Image(systemName: message.rating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup") }
                Button { store.sendFeedback(messageID: message.id, rating: -1, correction: nil) } label: { Image(systemName: message.rating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown") }
                Button { text = message.content; correcting = true } label: { Label("Correct", systemImage: "pencil") }
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            .sheet(isPresented: Binding(get: { correcting }, set: { correcting = $0 })) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Write the answer it should have given").font(.headline)
                    TextEditor(text: $text).font(.body).frame(minHeight: 220).border(.quaternary)
                    Text("Emails, phone numbers, IPs, card numbers and keys are removed before saving.").font(.caption).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("Cancel") { correcting = false }
                        Button("Save correction") { store.sendFeedback(messageID: message.id, rating: -1, correction: text); correcting = false }.keyboardShortcut(.defaultAction) }
                }.padding(20).frame(width: 560)
            }
        }
    }
}

struct RedXAIView: View {
    @Local var stats: [String: Any] = [:]
    @Local var err = ""
    @Local var ingestText = ""
    @Local var ingestSource = ""
    @Local var seeds = ""
    @Local var maxPages = 200
    @Local var delay = 2.0
    @Local var busy = ""
    @AppStorage("trainingMode", store: AccountProfile.preferences) var trainingMode = false
    @AppStorage("trainingConsent", store: AccountProfile.preferences) var trainingConsent = false
    @Local var distill: [String: Any] = [:]
    @Local var st: [String: Any] = [:]
    @Local var stKind = ""
    @Local var stEndpoint = ""
    @Local var stRegion = ""
    @Local var stBucket = ""
    @Local var stPrefix = "vortex-train"
    @Local var stAccess = ""
    @Local var stUser = ""
    @Local var stSecret = ""
    func load() async {
        do {
            stats = try await Admin.call("GET", "/admin/redxai/stats")
            distill = (try? await Admin.call("GET", "/admin/redxai/distill")) ?? [:]
            st = (try? await Admin.call("GET", "/admin/storage")) ?? [:]
            if let c = st["config"] as? [String: Any] {
                stKind = c["kind"] as? String ?? ""; stEndpoint = c["endpoint"] as? String ?? ""; stRegion = c["region"] as? String ?? ""
                stBucket = c["bucket"] as? String ?? ""; stPrefix = (c["prefix"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "vortex-train"
                stAccess = c["access_key"] as? String ?? ""; stUser = c["username"] as? String ?? ""
            }
            let c = try await Admin.call("GET", "/admin/redxai/crawl-config")
            seeds = (c["seeds"] as? [String] ?? []).joined(separator: "\n"); maxPages = c["max_pages"] as? Int ?? 200; delay = c["delay_seconds"] as? Double ?? 2
            err = ""
        } catch { err = error.localizedDescription }
    }
    func n(_ k: String) -> Int { stats[k] as? Int ?? 0 }
    var versions: [String] { stats["versions"] as? [String] ?? [] }
    var active: String { (stats["config"] as? [String: Any])?["active_version"] as? String ?? "" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Vortex").font(.largeTitle.bold())
                    Text("your learning model, built on open models").foregroundStyle(.secondary)
                    Spacer(); Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                }
                Text("Use the model \"vortex\" (alias \"red-xai\") in chat or any app. It answers with its persona, remembers everything in its knowledge store, routes code to the coder, and improves through versioned LoRA adapters trained on your ratings and corrections.").font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    stat("Knowledge chunks", n("knowledge_chunks")); stat("Ratings", n("feedback")); stat("👍", n("thumbs_up")); stat("👎", n("thumbs_down")); stat("Corrections", n("corrections"))
                }
                GroupBox("Training mode (off by default)") {
                    VStack(alignment: .leading) {
                        Toggle("Collect my ratings and corrections for training", isOn: $trainingMode)
                        Toggle("I consent to storing these chats (PII scrubbed) on my server for training", isOn: $trainingConsent).disabled(!trainingMode)
                        Text("When on, every reply gets 👍 👎 and Correct buttons. Nothing is collected while it's off.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Learn from the active model (distillation)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Vortex learns from whatever model I chat with", isOn: Binding(get: { distill["learning_on"] as? Bool ?? false }, set: { v in Task { _ = try? await Admin.call("POST", "/admin/redxai/config", ["learn": v]); await load() } }))
                        Text("Only while Training mode + consent are on in this app: each reply from the active model (or merge) is captured, PII scrubbed and sealed. A judge model scores them; only the best (score ≥ \(distill["min_score"] ?? 8)) and your 👍/corrections are exported to train the next Vortex version.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("Captured \(distill["captured"] ?? 0) · scored \(distill["scored"] ?? 0) · best \(distill["best"] ?? 0)")
                            Spacer()
                            Button("Score now") { Task { _ = try? await Admin.call("POST", "/admin/redxai/distill/score", ["limit": 50]); err = "Scoring up to 50 captures in the background." } }
                        }
                        if let t = distill["teachers"] as? [String: Any], !t.isEmpty { Text("Teachers: " + t.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")).font(.caption) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Overflow storage for training data") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Disk \(st["disk_pct"] ?? 0)% used. At \(st["threshold"] ?? 80)% closed training files are sealed on the server and moved here, verified, then deleted locally. \(st["pending"] ?? 0) file(s) eligible, \((st["offloaded"] as? [Any])?.count ?? 0) offloaded.").font(.caption)
                        Picker("Backend", selection: $stKind) { Text("Off").tag(""); Text("S3-compatible (Vultr Object Storage, R2, B2…)").tag("s3"); Text("WebDAV (https)").tag("webdav"); Text("TeraBox (needs Open Platform app)").tag("terabox") }
                        if stKind == "s3" { TextField("Endpoint, e.g. https://ewr1.vultrobjects.com", text: $stEndpoint); HStack { TextField("Bucket", text: $stBucket); TextField("Region (us-east-1)", text: $stRegion) }; TextField("Access key", text: $stAccess) }
                        if stKind == "webdav" { TextField("https://… WebDAV folder URL", text: $stEndpoint); TextField("Username", text: $stUser) }
                        if stKind == "terabox" { Text("TeraBox's official API requires an approved developer app and OAuth token. Not enabled yet — use S3 or WebDAV for now.").font(.caption).foregroundStyle(.orange) }
                        if stKind == "s3" || stKind == "webdav" {
                            TextField("Folder prefix", text: $stPrefix)
                            SecureField((st["secret_set"] as? Bool ?? false) ? "Secret (saved; type to replace)" : "Secret key / password", text: $stSecret)
                        }
                        HStack {
                            Button("Save") { Task { var b: [String: Any] = ["kind": stKind, "endpoint": stEndpoint, "region": stRegion, "bucket": stBucket, "prefix": stPrefix, "access_key": stAccess, "username": stUser]; if !stSecret.isEmpty { b["secret"] = stSecret }; _ = try? await Admin.call("POST", "/admin/storage", b); stSecret = ""; err = "Storage saved (secret sealed on the server)"; await load() } }
                            Button("Test") { Task { let r = try? await Admin.call("POST", "/admin/storage/test", [:]); err = (r?["ok"] as? Bool ?? false) ? "Storage works ✅" : "Storage test failed: \(r?["error"] ?? "")" } }
                            Button("Offload now") { Task { let r = try? await Admin.call("POST", "/admin/storage/offload", ["force": true]); err = "Offload: moved \(r?["moved"] ?? 0) \(r?["error"] ?? "")"; await load() } }.disabled(stKind.isEmpty)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Teach it (knowledge store)") {
                    VStack(alignment: .leading) {
                        TextEditor(text: $ingestText).frame(height: 90).border(.quaternary)
                        HStack {
                            TextField("Source label (e.g. notes:product)", text: $ingestSource)
                            Button(busy == "ingest" ? "Learning…" : "Add to knowledge") {
                                busy = "ingest"
                                Task { do { let r = try await Admin.call("POST", "/v1/redxai/ingest", ["text": ingestText, "source": ingestSource.isEmpty ? "vortex-app" : ingestSource]); err = "Added \(r["chunks_added"] ?? 0) chunks"; ingestText = "" } catch { err = error.localizedDescription }; busy = ""; await load() }
                            }.disabled(ingestText.count < 40 || !busy.isEmpty)
                        }
                    }.padding(4)
                }
                GroupBox("Web crawler (respects robots.txt)") {
                    VStack(alignment: .leading) {
                        Text("Seed URLs, one per line").font(.caption)
                        TextEditor(text: $seeds).frame(height: 70).border(.quaternary)
                        HStack {
                            Stepper("Max pages: \(maxPages)", value: $maxPages, in: 1...5000, step: 50)
                            Stepper("Delay: \(delay, specifier: "%.0f") s/page", value: $delay, in: 1...30)
                            Spacer()
                            Button("Save") { Task { _ = try? await Admin.call("POST", "/admin/redxai/crawl-config", ["seeds": seeds.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("http") }, "max_pages": maxPages, "delay_seconds": delay, "same_domain": true]); err = "Crawler saved" } }
                            Button("Crawl now") { Task { _ = try? await Admin.call("POST", "/admin/redxai/crawl"); err = "Crawling in the background. Refresh to see new knowledge." } }
                        }
                    }.padding(4)
                }
                GroupBox("Versions & how smart it is") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Active:").bold(); Text(active.isEmpty ? "base model + memory" : "vortex-\(active)")
                            Spacer()
                            Menu("Switch version") {
                                Button("Base (no adapter)") { Task { _ = try? await Admin.call("POST", "/admin/redxai/config", ["active_version": ""]); await load() } }
                                ForEach(versions, id: \.self) { v in Button(v) { Task { _ = try? await Admin.call("POST", "/admin/redxai/config", ["active_version": v]); await load() } } }
                            }.fixedSize()
                            Button("Run benchmark") { Task { _ = try? await Admin.call("POST", "/admin/redxai/eval"); err = "Benchmark running (a few minutes). Refresh to see scores." } }
                            Button("Export training data") { Task { if let r = try? await Admin.call("POST", "/admin/redxai/export") { err = "Exported \(r["examples"] ?? 0) examples on the server: \(r["file"] ?? "")" } } }
                        }
                        if let ev = stats["eval"] as? [String: Any], let latest = ev["latest"] as? [String: Any], let res = latest["results"] as? [String: [String: Any]] {
                            ForEach(res.keys.sorted(), id: \.self) { m in
                                HStack { Text(m).font(.body.monospaced()); Spacer(); Text("score \(res[m]?["score"] ?? 0)%  ·  \(res[m]?["avg_seconds"] ?? 0)s avg") }
                            }
                            if let hist = ev["history"] as? [[String: Any]], hist.count > 1 {
                                Text("History: " + hist.suffix(8).map { h in (h["scores"] as? [String: Any])?.map { "\($0.key) \($0.value)" }.joined(separator: ", ") ?? "" }.joined(separator: "  →  ")).font(.caption).foregroundStyle(.secondary)
                            }
                        } else { Text("No benchmark yet.").foregroundStyle(.secondary) }
                        Text("Real learning = LoRA fine-tunes. Training needs a GPU to be practical: export, train on a rented GPU (see docs/VORTEX.md), then on the server run `redxai-train install adapter.gguf` and it shows up here as v1, v2, …").font(.caption).foregroundStyle(.secondary)
                    }.padding(4)
                }
                GroupBox("Capabilities") {
                    VStack(alignment: .leading) {
                        Text("Chat + memory ✅   Coding (routes to coder) ✅   Reasoning ✅   Embeddings ✅")
                        Text("Image (stable-diffusion.cpp, CPU, slow): \((stats["image"] as? Bool ?? false) ? "✅ ready" : "⏳ installing")")
                        Text("Music/sound (MusicGen-small, CPU, slow): \((stats["audio"] as? Bool ?? false) ? "✅ ready" : "⏳ installing")")
                        Text("PC control: planned — an opt-in local agent, off by default, confirms every action. Give other apps redx_xai_ keys with scopes in API Keys.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                if !err.isEmpty { Text(err).font(.caption).foregroundStyle(.orange) }
            }.padding(20)
        }.task { await load() }
    }
    func stat(_ t: String, _ v: Int) -> some View {
        VStack { Text("\(v)").font(.title2.bold()); Text(t).font(.caption).foregroundStyle(.secondary) }
            .frame(minWidth: 90).padding(8).background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}
