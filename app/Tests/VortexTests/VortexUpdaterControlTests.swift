import XCTest
@testable import Vortex

final class VortexUpdaterControlTests: XCTestCase {
    func testManualUpdateWorksEvenWhenAutomaticUpdatesAreDisabled() {
        XCTAssertTrue(Updater.shouldCheck(autoEnabled: false, manual: true))
        XCTAssertTrue(Updater.shouldCheck(autoEnabled: true, manual: false))
        XCTAssertFalse(Updater.shouldCheck(autoEnabled: false, manual: false))
    }
    func testVersionComparisonSupportsPatchReleases() {
        XCTAssertTrue(Updater.newer("v2.11.2", "2.11.1"))
        XCTAssertTrue(Updater.newer("v2.11.1", "2.11"))
        XCTAssertFalse(Updater.newer("v2.11", "2.11.2"))
        XCTAssertFalse(Updater.newer("v2.11.2", "2.11.2"))
        XCTAssertEqual(try? Updater.validateSignedVersion("2.11.2\n", requested:"v2.11.2", current:"2.11.1"), "2.11.2")
    }
}
