import XCTest
@testable import DikteNative

final class MemoryPressureMonitorTests: XCTestCase {
    @MainActor
    func testUtilityQueueEventsCrossToMainActorWithoutDroppingEvents() async {
        let monitor = MemoryPressureMonitor(startSystemSource: false)
        let receivedAll = expectation(description: "all pressure events arrived")
        var received: [MemoryPressureLevel] = []
        let consumer = Task { @MainActor in
            for await level in monitor.events {
                XCTAssertTrue(Thread.isMainThread)
                received.append(level)
                if received.count == 100 {
                    receivedAll.fulfill()
                    return
                }
            }
        }

        DispatchQueue.global(qos: .utility).async {
            for index in 0..<100 {
                monitor.emitForTesting(index.isMultiple(of: 2) ? .warning : .critical)
            }
        }

        await fulfillment(of: [receivedAll], timeout: 2)
        XCTAssertEqual(received.count, 100)
        consumer.cancel()
        monitor.cancel()
    }

    func testPressurePolicyByPipelineState() {
        XCTAssertEqual(MemoryPressurePolicy.action(for: .normal, phase: .idle), .none)
        XCTAssertEqual(MemoryPressurePolicy.action(for: .warning, phase: .idle), .releaseNow)
        XCTAssertEqual(
            MemoryPressurePolicy.action(for: .critical,
                                        phase: .arming(startedAt: Date(), attempt: 1)),
            .releaseNow
        )
        XCTAssertEqual(
            MemoryPressurePolicy.action(for: .warning,
                                        phase: .recording(startedAt: Date())),
            .releaseNow
        )
        XCTAssertEqual(
            MemoryPressurePolicy.action(for: .critical,
                                        phase: .processing(.transcribing)),
            .deferRelease
        )
    }

    func testPendingReleaseIsAppliedForEveryIdleExitKind() {
        for exit in ["success", "error", "cancel"] {
            XCTAssertTrue(
                MemoryPressurePolicy.shouldReleaseOnReturnToIdle(pending: true, level: .normal),
                "\(exit) must apply the deferred release"
            )
        }
        XCTAssertTrue(MemoryPressurePolicy.shouldReleaseOnReturnToIdle(pending: false, level: .warning))
        XCTAssertFalse(MemoryPressurePolicy.shouldReleaseOnReturnToIdle(pending: false, level: .normal))
    }

    func testCancelMakesDelayedEventsHarmless() async throws {
        let monitor = MemoryPressureMonitor(startSystemSource: false)
        monitor.cancel()
        monitor.emitForTesting(.critical)

        let first = await withTaskGroup(of: MemoryPressureLevel?.self) { group in
            group.addTask {
                for await level in monitor.events { return level }
                return nil
            }
            return await group.next() ?? nil
        }
        XCTAssertNil(first)
    }
}
