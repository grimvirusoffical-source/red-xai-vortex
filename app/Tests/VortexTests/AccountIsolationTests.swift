import XCTest
@testable import Vortex

final class AccountIsolationTests: XCTestCase {
    func testVerifiedSubjectHasStableDisjointNamespace() throws {
        let a = try AccountProfile.identifier(subject: "rxa_account_a")
        let b = try AccountProfile.identifier(subject: "rxa_account_b")
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(a, try AccountProfile.identifier(subject: "rxa_account_a"))
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.contains("rxa_"))
        XCTAssertThrowsError(try AccountProfile.identifier(subject: ""))
        XCTAssertThrowsError(try AccountProfile.identifier(subject: "A\u{0}B"))
        XCTAssertThrowsError(try AccountProfile.identifier(subject: String(repeating: "x", count: 513)))
    }
    func testOwnerNeverSubstitutesForAccountSignIn() async {
        await MainActor.run {
            let gate = AccountGate()
            gate.termsOK = true; gate.owner = true; gate.signedIn = false
            gate.requireAccountSignIn = false
            XCTAssertFalse(gate.ready)
            gate.continueAsOwner()
            XCTAssertFalse(gate.ready)
            gate.signedIn = true
            XCTAssertTrue(gate.ready)
            gate.termsOK = false
            XCTAssertFalse(gate.ready)
        }
    }
    func testAnonymousProfileDoesNotReadLegacyCredentialService() {
        XCTAssertNotEqual(AccountProfile.credentialService, "com.redxai.dolphino")
        XCTAssertNotEqual(AccountProfile.directory.lastPathComponent, "Red-XAI Vortex")
        XCTAssertEqual(AccountProfile.service(for: "redx-session"), "com.redxai.vortex.authentication.v2")
        if !AccountProfile.isActive { XCTAssertNil(AccountProfile.service(for: "admin-primary")) }
    }
}
