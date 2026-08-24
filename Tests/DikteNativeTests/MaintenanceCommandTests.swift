import XCTest
@testable import DikteNative

final class MaintenanceCommandTests: XCTestCase {
    func testParsesLoginItemUnregisterCommand() {
        XCTAssertEqual(
            MaintenanceCommand.parse(arguments: ["DikteNative", "--maintenance-unregister-login-item"]),
            .unregisterLoginItem
        )
    }

    func testNormalLaunchDoesNotEnterMaintenanceMode() {
        XCTAssertNil(MaintenanceCommand.parse(arguments: ["DikteNative"]))
    }
}
