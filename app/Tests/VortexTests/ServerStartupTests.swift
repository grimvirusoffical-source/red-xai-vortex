import XCTest
@testable import Vortex

final class ServerStartupTests: XCTestCase {
    @MainActor private func withFixture(_ body: (ServerDef, MCPServerDef) throws -> Void) throws {
        XCTAssertTrue(AccountProfile.isTesting, "Never run startup fixtures against real account data")
        guard AccountProfile.isTesting else { return }
        let directory = AccountProfile.directory
        let serverFile = directory.appendingPathComponent("servers.json")
        let mcpFile = directory.appendingPathComponent("mcp.json")
        let savedFiles = [serverFile, mcpFile].map { ($0, try? Data(contentsOf: $0)) }
        let preferences = AccountProfile.preferences
        let names = ["activeServer", "serverURL", "adminBaseURL", "connectionMode"]
        let savedPreferences = names.map { ($0, preferences.object(forKey: $0)) }
        let gate = AccountGate.shared
        let savedTerms = gate.termsOK, savedSignedIn = gate.signedIn
        defer {
            gate.termsOK = savedTerms; gate.signedIn = savedSignedIn
            for (file, data) in savedFiles {
                if let data { try? data.write(to: file, options: .atomic) }
                else { try? FileManager.default.removeItem(at: file) }
            }
            for (key, value) in savedPreferences {
                if let value { preferences.set(value, forKey: key) }
                else { preferences.removeObject(forKey: key) }
            }
        }
        var placeholder = ServerDef(name: "Main server", sshHost: "root@YOUR_SERVER",
                                    keyPath: directory.appendingPathComponent("no-ssh-key").path,
                                    localPort: 18092, primary: true)
        placeholder.id = "placeholder-primary"
        var firecrawl = MCPServerDef(id: "firecrawl-fixture", name: "Firecrawl")
        firecrawl.type = "http"; firecrawl.url = "https://mcp.firecrawl.dev/v2/mcp"
        firecrawl.enabled = true; firecrawl.authMode = "bearer"
        firecrawl.secretReference = "fixture-reference-only"
        try JSONEncoder().encode([placeholder]).write(to: serverFile, options: .atomic)
        try JSONEncoder().encode([firecrawl]).write(to: mcpFile, options: .atomic)
        preferences.set(placeholder.id, forKey: "activeServer")
        preferences.set("http://127.0.0.1:18191/v1", forKey: "serverURL")
        preferences.set("unchanged-before-startup", forKey: "adminBaseURL")
        preferences.set("link", forKey: "connectionMode")
        gate.termsOK = true
        XCTAssertTrue(gate.acceptVerifiedIdentity(subject: "test-account", displayName: "Startup fixture"))
        XCTAssertTrue(gate.ready)
        try body(placeholder, firecrawl)
    }

    func testPlaceholderAndSavedEnabledFirecrawlHydrateWithoutActivating() async throws {
        try await MainActor.run {
            try withFixture { placeholder, firecrawl in
                let mcpFile = AccountProfile.directory.appendingPathComponent("mcp.json")
                let originalMCP = try Data(contentsOf: mcpFile)
                let store = ServerStore()
                defer { store.stopAll() }
                let mcp = MCPStore()
                XCTAssertEqual(store.active?.id, placeholder.id)
                XCTAssertFalse(store.connectionsStarted)
                XCTAssertTrue(store.tunnels.isEmpty)
                XCTAssertEqual(AccountProfile.preferences.string(forKey: "adminBaseURL"), "unchanged-before-startup",
                               "The initializer must not call activate or write connection settings")
                XCTAssertEqual(mcp.servers.first?.id, firecrawl.id)
                XCTAssertEqual(mcp.servers.first?.enabled, true)
                XCTAssertEqual(mcp.servers.first?.secretReference, "fixture-reference-only")
                XCTAssertTrue(mcp.tools.isEmpty)
                XCTAssertEqual(try Data(contentsOf: mcpFile), originalMCP, "Recovery must not reset saved MCP servers")
            }
        }
    }

    func testInvalidActiveServerSelectsOnlyUsablePrimaryWithoutStartingIt() async throws {
        try await MainActor.run {
            try withFixture { _, _ in
                var bad = ServerDef(name: "Unconfigured", sshHost: "root@YOUR_SERVER", localPort: 18094)
                bad.id = "invalid-active"
                var good = ServerDef(name: "Configured", sshHost: "user@server.invalid", localPort: 18092, primary: true)
                good.id = "valid-primary"
                try JSONEncoder().encode([bad, good]).write(to: AccountProfile.directory.appendingPathComponent("servers.json"), options: .atomic)
                AccountProfile.preferences.set(bad.id, forKey: "activeServer")
                let store = ServerStore(); defer { store.stopAll() }
                XCTAssertEqual(store.activeID, good.id)
                XCTAssertTrue(store.tunnels.isEmpty)
                XCTAssertFalse(store.connectionsStarted)
                XCTAssertEqual(AccountProfile.preferences.string(forKey: "activeServer"), bad.id)
                XCTAssertEqual(AccountProfile.preferences.string(forKey: "adminBaseURL"), "unchanged-before-startup")
            }
        }
    }

    func testLinkOnlyServerDoesNotRequireAnSSHHost() async throws {
        try await MainActor.run {
            try withFixture { placeholder, _ in
                var linkOnly = placeholder; linkOnly.id = "link-only"; linkOnly.primary = false
                linkOnly.sshHost = ""; linkOnly.linkAddr = "model.example:8093"
                var good = placeholder; good.id = "ssh-primary"; good.sshHost = "user@other.invalid"
                try JSONEncoder().encode([linkOnly, good]).write(to: AccountProfile.directory.appendingPathComponent("servers.json"), options: .atomic)
                AccountProfile.preferences.set(linkOnly.id, forKey: "activeServer")
                let store = ServerStore(); defer { store.stopAll() }
                XCTAssertEqual(store.activeID, linkOnly.id)
                XCTAssertTrue(store.tunnels.isEmpty)
                XCTAssertEqual(RedXLink.address(linkOnly), "model.example:8093")
            }
        }
    }

    func testSignedOutStartupCannotStartMonitorOrTunnel() async throws {
        try await MainActor.run {
            try withFixture { placeholder, _ in
                AccountGate.shared.signedIn = false
                let store = ServerStore(); defer { store.stopAll() }
                store.startConnections(); store.ensureTunnel(placeholder)
                XCTAssertFalse(store.connectionsStarted)
                XCTAssertTrue(store.tunnels.isEmpty)
            }
        }
    }

    func testPlaceholderNeverCreatesATunnelAndStartupCanBeStopped() async throws {
        try await MainActor.run {
            try withFixture { placeholder, _ in
                XCTAssertFalse(ServerStore.validHost(placeholder.sshHost))
                XCTAssertNil(RedXLink.address(placeholder))
                let store = ServerStore(); defer { store.stopAll() }
                store.ensureTunnel(placeholder)
                XCTAssertTrue(store.tunnels.isEmpty)
                store.startConnections(); store.startConnections()
                XCTAssertTrue(store.connectionsStarted)
                XCTAssertTrue(store.tunnels.isEmpty)
                store.stopAll()
                XCTAssertFalse(store.connectionsStarted)
            }
        }
    }
}
