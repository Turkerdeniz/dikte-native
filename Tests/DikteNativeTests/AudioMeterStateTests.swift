import XCTest
@testable import DikteNative

@MainActor
final class AudioMeterStateTests: XCTestCase {
    func testFastProducerIsBoundedAndRenderedAtMostThirtyFramesPerSecond() async throws {
        let meter = AudioMeterState()
        let sink = meter.start()
        // 60,000 samples is ten minutes of a 100 Hz producer delivered as fast as
        // possible, which is stricter than real-time for queue-growth detection.
        for index in 0..<60_000 { sink.yield(Float(index % 100) / 100) }
        try await Task.sleep(for: .milliseconds(120))

        let statistics = meter.statistics()
        XCTAssertEqual(statistics.receivedCount, 60_000)
        XCTAssertLessThanOrEqual(statistics.renderedCount, 4)
        XCTAssertGreaterThan(statistics.coalescedCount, 0)
        XCTAssertLessThanOrEqual(statistics.coalescedCount, statistics.receivedCount)
        meter.stop()
    }

    func testStopResetsWaveformAndTerminatesConsumer() async throws {
        let meter = AudioMeterState()
        let sink = meter.start()
        sink.yield(1)
        try await Task.sleep(for: .milliseconds(45))
        XCTAssertGreaterThan(meter.levels.max() ?? 0, 0)

        let stopped = meter.stop()
        sink.yield(1)
        try await Task.sleep(for: .milliseconds(45))
        XCTAssertEqual(meter.levels, [Float](repeating: 0, count: 34))
        XCTAssertEqual(meter.statistics().receivedCount, 0)
        XCTAssertGreaterThanOrEqual(stopped.renderedCount, 1)
    }

    func testWarmModelPolicyIsFortyFiveSeconds() {
        XCTAssertEqual(ModelLifecyclePolicy.warmModelSeconds, 45)
    }
}
