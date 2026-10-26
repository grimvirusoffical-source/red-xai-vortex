import XCTest
@testable import Vortex
final class OwnerAuditTests: XCTestCase {
    func testExportRequiresSuccessfulLocalSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vortex-audit-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(#"{"events":[{"id":"fixture"}]}"#.utf8)
        let url = directory.appendingPathComponent("audit.json")
        try OwnerAuditExport.save(data, to: url)
        XCTAssertEqual(try Data(contentsOf: url), data)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try OwnerAuditExport.save(data, to: directory.appendingPathComponent("missing/audit.json")))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
