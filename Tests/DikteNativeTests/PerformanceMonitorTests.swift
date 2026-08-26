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

    func testLegacyPerformanceDiagnosticsDecodeWithoutVisualMetrics() throws {
        let json = """
        {"stages":[],"totalMilliseconds":10,"userCPUMilliseconds":2,
        "systemCPUMilliseconds":1,"residentBytesStart":10,"residentBytesEnd":11,
        "physicalFootprintBytesStart":12,"physicalFootprintBytesEnd":13,
        "diskReadBytes":0,"diskWrittenBytes":0,"threadCountStart":8,
        "threadCountEnd":9,"thermalState":"Normal"}
        """
        let value = try JSONDecoder().decode(PerformanceDiagnostics.self, from: Data(json.utf8))
        XCTAssertNil(value.audioLevelReceivedCount)
        XCTAssertNil(value.modelLoadMilliseconds)
        XCTAssertNil(value.maximumOverlayQueryMilliseconds)
    }
}
