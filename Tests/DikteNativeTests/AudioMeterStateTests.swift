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
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(meter.levels.max() ?? 0, 0)

        let stopped = meter.stop()
        sink.yield(1)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(meter.levels,
                       [Float](repeating: 0, count: AudioMeterState.historyLength))
        XCTAssertEqual(meter.statistics().receivedCount, 0)
        XCTAssertGreaterThanOrEqual(stopped.renderedCount, 1)
    }

    func testSamplesArrivingWithinOneTickAreFoldedToTheirPeak() async throws {
        // Drivers do not deliver on the meter's grid: a burst that lands between
        // two ticks has to reach the bar as its loudest sample. Spreading a burst
        // across later ticks instead is what let the display fall behind the
        // microphone whenever the driver ran faster than 30 Hz.
        let meter = AudioMeterState()
        let sink = meter.start()
        sink.yield(0.2)
        sink.yield(0.9)
        sink.yield(0.3)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(meter.statistics().coalescedCount, 2)
        // 0.9 through one attack step of the smoother. Taking the window's last
        // sample would give 0.165 and taking its oldest — what the queue used to
        // hand back — 0.11, so this separates all three.
        XCTAssertEqual(meter.levels.max() ?? 0,
                       0.9 * AudioLevelSmoother.attack, accuracy: 0.001)
        meter.stop()
    }

    func testSilenceStillAdvancesTheWaveformSoTheScrollNeverStalls() async throws {
        let meter = AudioMeterState()
        meter.start()
        let before = meter.lastSampleAt
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertGreaterThan(meter.lastSampleAt, before)
        XCTAssertGreaterThanOrEqual(meter.statistics().renderedCount, 0)
        meter.stop()
    }

    func testSchedulingSlopIsAbsorbedByTheGridRatherThanAddedToTheNextInterval() {
        let interval = AudioMeterState.frameInterval
        let tick = ContinuousClock.now

        // On time, and late by less than a whole interval: the grid holds, so a
        // string of slightly-late wake-ups cannot walk the cadence off 30 Hz.
        XCTAssertEqual(AudioMeterState.nextGridPoint(after: tick, now: tick),
                       tick.advanced(by: interval))
        let slightlyLate = tick.advanced(by: .milliseconds(10))
        XCTAssertEqual(AudioMeterState.nextGridPoint(after: tick, now: slightlyLate),
                       tick.advanced(by: interval))

        // Late enough to have missed its own successor: re-anchor once, rather
        // than firing every grid point it slept through back to back.
        let veryLate = tick.advanced(by: .milliseconds(100))
        XCTAssertEqual(AudioMeterState.nextGridPoint(after: tick, now: veryLate),
                       veryLate.advanced(by: interval))
    }

    func testWarmModelPolicyIsFortyFiveSeconds() {
        XCTAssertEqual(ModelLifecyclePolicy.warmModelSeconds, 45)
    }
}

final class WaveformGeometryTests: XCTestCase {
    private let compact = WaveformGeometry(barWidth: 2.5, spacing: 2)

    func testBarCountCoversTheViewportPlusTheOneSlidingIn() {
        // The compact pill's waveform viewport, measured off the shipped layout:
        // 286 - 22 padding - 10 dot - 8 - 8 - 42 timer - 8 - 24 stop = 164.
        XCTAssertEqual(compact.barCount(forWidth: 164), 38)
        XCTAssertEqual(compact.pitch, 4.5)
        XCTAssertEqual(compact.barCount(forWidth: 0), 0)
    }

    func testViewportIsFilledForEveryOffsetTheScrollCanReach() {
        let width: CGFloat = 164
        let count = compact.barCount(forWidth: width)
        for step in 0...10 {
            let offset = compact.pitch * CGFloat(step) / 10
            let newestTrailingEdge = compact.x(forIndexFromNewest: 0, width: width,
                                               offset: offset) + compact.barWidth
            let oldestLeadingEdge = compact.x(forIndexFromNewest: count - 1, width: width,
                                              offset: offset)
            // The leading edge is always covered, and the trailing edge is never
            // uncovered by more than one pitch, which the edge fade hides.
            XCTAssertLessThanOrEqual(oldestLeadingEdge, 0)
            XCTAssertGreaterThanOrEqual(newestTrailingEdge, width - compact.pitch)
        }
    }

    /// The anchor the pill is judged against is the waveform viewport's own 50%,
    /// not the pill's geometric centre — the timer and stop button sit to the
    /// right of the viewport, so the two are 32 pt apart by design.
    func testVisibleSpanStaysCentredOnTheViewportsOwnFiftyPercent() {
        let width: CGFloat = 164
        let count = compact.barCount(forWidth: width)
        for step in 0...10 {
            let offset = compact.pitch * CGFloat(step) / 10
            let trailing = compact.x(forIndexFromNewest: 0, width: width, offset: offset)
                + compact.barWidth
            let leading = compact.x(forIndexFromNewest: count - 1, width: width, offset: offset)
            // What is seen is the span clipped to the viewport; the strip
            // overhangs the leading edge so that clip is what defines the centre.
            let visible = (max(0, leading) + min(width, trailing)) / 2

            XCTAssertEqual(visible, width / 2, accuracy: compact.pitch / 2)
        }
    }

    func testScrollOffsetIsAFunctionOfElapsedTimeAndIsClampedToOnePitch() {
        let now = Date()
        let interval = AudioMeterState.sampleInterval

        XCTAssertEqual(compact.scrollOffset(since: now, at: now, interval: interval), 0)
        XCTAssertEqual(compact.scrollOffset(since: now, at: now.addingTimeInterval(interval / 2),
                                            interval: interval),
                       compact.pitch / 2, accuracy: 0.001)
        // A stalled meter parks the strip instead of letting it run away.
        XCTAssertEqual(compact.scrollOffset(since: now, at: now.addingTimeInterval(interval * 9),
                                            interval: interval),
                       compact.pitch)
        // A clock that steps backwards must not push the strip the wrong way.
        XCTAssertEqual(compact.scrollOffset(since: now, at: now.addingTimeInterval(-1),
                                            interval: interval), 0)
    }

    func testHistoryIsLongEnoughToFillBothOverlayWaveforms() {
        let wide = WaveformGeometry(barWidth: 3, spacing: 2.5)
        XCTAssertGreaterThanOrEqual(AudioMeterState.historyLength,
                                    compact.barCount(forWidth: 164))
        XCTAssertGreaterThanOrEqual(AudioMeterState.historyLength,
                                    wide.barCount(forWidth: 239))
    }
}
