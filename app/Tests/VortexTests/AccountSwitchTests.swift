import XCTest
@testable import Vortex

final class AccountSwitchTests: XCTestCase {
    func testOwnerCredentialNeverBypassesAccountAuthentication() async {
        await MainActor.run {
            let account = AccountGate()
            account.termsOK = true; account.owner = true; account.signedIn = false
            XCTAssertFalse(account.ready)
            account.continueAsOwner()
            XCTAssertFalse(account.ready, "a saved admin credential is not an account login")
            account.signedIn = true
            XCTAssertFalse(account.ready, "a UI flag without a verified subject cannot unlock data")
        }
    }
    func testMatchingVerifiedAccountOpensOnlyItsProfile() async {
        await MainActor.run {
            let account = AccountGate(); account.termsOK = true
            XCTAssertTrue(account.acceptVerifiedIdentity(subject: "test-account", displayName: "Fixture"))
            XCTAssertTrue(account.ready)
            XCTAssertEqual(account.verifiedSubject, "test-account")
            XCTAssertFalse(account.acceptVerifiedIdentity(subject: "different-account", displayName: "Other"))
            XCTAssertTrue(account.restartRequired)
            XCTAssertFalse(account.ready)
            XCTAssertFalse(account.owner)
        }
    }
    func testImmutableAccountNamespacesUseIssuerAndSubjectNotDisplayName() throws {
        let a = try AccountProfile.identifier(subject: "alice")
        let b = try AccountProfile.identifier(subject: "bob")
        XCTAssertEqual(a.count, 64); XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, try AccountProfile.identifier(subject: "alice", issuer: "https://other.example"))
        XCTAssertThrowsError(try AccountProfile.identifier(subject: ""))
        XCTAssertThrowsError(try AccountProfile.identifier(subject: "bad\nsubject"))
        XCTAssertFalse(a.contains("/"))
        XCTAssertTrue(AccountProfile.directory.path.contains("Profiles"))
    }
}
