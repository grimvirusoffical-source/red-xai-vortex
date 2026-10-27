import XCTest
@testable import Vortex

final class GatewayHTTPErrorTests: XCTestCase {
    func testForbiddenScopeAndModelReasonsAreVisibleWithoutEscalation() {
        for reason in [
            "key lacks scope chat",
            "this key may not use model vortex-mini",
            "IP not allowed for this key",
            "device or IP banned",
        ] {
            let data = try! JSONSerialization.data(withJSONObject: ["error": ["message": reason]])
            let error = API.gatewayError(403, data)
            XCTAssertEqual(error.code, 403)
            XCTAssertTrue(error.localizedDescription.contains(reason))
            XCTAssertTrue(error.localizedDescription.contains("HTTP 403"))
        }
    }
    func testMissingOrInvalidKeyIsDistinguishedFromAccessDenial() {
        let error = API.gatewayError(401, Data())
        XCTAssertEqual(error.code, 401)
        XCTAssertTrue(error.localizedDescription.contains("API key"))
        let unknown = API.gatewayError(403, Data("<html>Forbidden</html>".utf8))
        XCTAssertEqual(unknown.code, 403)
        XCTAssertTrue(unknown.localizedDescription.contains("HTTP 403"))
    }
}
