import XCTest
@testable import DikteNative

@MainActor
final class PerformanceMonitorTests: XCTestCase {
    func testTrackerCanCaptureStartAndFinishWithoutCorruptingStack() {
        let tracker = PerformanceTracker()
        tracker.begin("Kayıt başlangıcı")
        let result = tracker.finish()

        XCTAssertGreaterThan(result.threadCountStart, 0)
        XCTAssertGreaterThan(result.residentBytesStart, 0)
        XCTAssertGreaterThan(result.physicalFootprintBytesStart, 0)
        XCTAssertEqual(result.stages.map(\.name), ["Kayıt başlangıcı"])
    }
}
