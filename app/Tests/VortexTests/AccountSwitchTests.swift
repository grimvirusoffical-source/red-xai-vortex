import XCTest
@testable import Vortex

final class AccountSwitchTests: XCTestCase {
    func testOwnerModeDoesNotBypassExplicitAccountSwitch() async {
        await MainActor.run {
            let originalFlag = UserDefaults.standard.object(forKey: "vortexRequireAccountSignIn")
            defer {
                if let originalFlag {
                    UserDefaults.standard.set(originalFlag, forKey: "vortexRequireAccountSignIn")
                } else {
                    UserDefaults.standard.removeObject(forKey: "vortexRequireAccountSignIn")
                }
            }

            let account = AccountGate()
            account.termsOK = true
            account.owner = true
            account.signedIn = false
            account.requireAccountSignIn = true
            XCTAssertFalse(account.ready, "signing out must open the login screen on an owner Mac")

            account.accountSignInSucceeded()
            account.signedIn = true
            XCTAssertTrue(account.ready, "a new Red-XAI sign-in must pass the account gate")

            account.signedIn = false
            account.requireAccountSignIn = true
            XCTAssertFalse(account.ready)
            account.continueAsOwner()
            XCTAssertFalse(account.ready, "owner credentials must never bypass account authentication")
        }
    }
}
