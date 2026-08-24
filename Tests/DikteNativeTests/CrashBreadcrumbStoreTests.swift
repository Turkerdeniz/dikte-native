import XCTest
@testable import DikteNative

final class CrashBreadcrumbStoreTests: XCTestCase {
    func testBreadcrumbPersistsOnlyPipelineMetadataAndClears() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dikte-breadcrumb-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("active-session.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CrashBreadcrumbStore(fileURL: url)

        store.begin(stage: "recording", modelLoaded: true, memoryPressureLevel: .normal)
        store.update(stage: "processing-transcribing", memoryPressureLevel: .warning)

        let recovered = try XCTUnwrap(store.recover())
        XCTAssertEqual(recovered.stage, "processing-transcribing")
        XCTAssertTrue(recovered.modelLoaded)
        XCTAssertEqual(recovered.memoryPressureLevel, .warning)

        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("rawTranscript"))
        XCTAssertFalse(json.contains("audio"))
        store.clear()
        XCTAssertNil(store.recover())
    }
}
