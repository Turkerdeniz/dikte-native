import XCTest
@testable import DikteNative

@MainActor
final class ModelIdleReleaseSchedulerTests: XCTestCase {
    func testScheduledReleaseRunsAfterDelay() async throws {
        let scheduler = ModelIdleReleaseScheduler()
        var fired = false
        scheduler.schedule(after: 0.02) { fired = true }

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(fired)
    }

    func testCancelledReleaseNeverRuns() async throws {
        let scheduler = ModelIdleReleaseScheduler()
        var fired = false
        scheduler.schedule(after: 0.02) { fired = true }
        scheduler.cancel()

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(fired)
    }

    func testNewScheduleReplacesOldTimer() async throws {
        let scheduler = ModelIdleReleaseScheduler()
        var events: [String] = []
        scheduler.schedule(after: 0.02) { events.append("old") }
        scheduler.schedule(after: 0.04) { events.append("new") }

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(events, ["new"])
    }
}
