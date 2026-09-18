import Foundation

struct AudioMeterStatistics: Equatable, Sendable {
    let receivedCount: Int
    let renderedCount: Int
    let coalescedCount: Int
    let maximumDeliveryLagMilliseconds: Double
}

private struct AudioMeterSample: Sendable {
    let level: Float
    let emittedAt: ContinuousClock.Instant
}

/// A thread-safe, small bounded handoff from CoreAudio to the presentation layer.
/// The callback appends to a queue that can never exceed `maximumPending`, so it
/// still cannot create an unbounded backlog of MainActor jobs.
///
/// The consumer no longer wakes on delivery. It runs on its own fixed grid and
/// takes whatever has arrived since the previous tick, which is why the queue
/// hands back the *peak* of that window rather than its oldest entry: the capture
/// drivers do not deliver at the same cadence, and folding a window down to its
/// loudest sample is what a level meter is supposed to show anyway. Taking the
/// oldest instead made the display lag further behind the microphone the faster
/// the driver ran.
final class AudioLevelSink: @unchecked Sendable {
    static let maximumPending = 8

    private let lock = NSLock()
    private var pending: [AudioMeterSample] = []
    private var receivedCount = 0
    private var renderedCount = 0
    private var coalescedCount = 0
    private var maximumDeliveryLagMilliseconds = 0.0

    func yield(_ level: Float) {
        let sample = AudioMeterSample(level: level.isFinite ? min(1, max(0, level)) : 0,
                                      emittedAt: ContinuousClock.now)
        lock.withLock {
            receivedCount += 1
            pending.append(sample)
            while pending.count > Self.maximumPending {
                pending.removeFirst()
                coalescedCount += 1
            }
        }
    }

    /// Everything that arrived since the last tick, folded to its loudest sample.
    /// The timestamp is the *oldest* folded sample's, so the reported lag stays
    /// the worst case rather than the flattering one.
    fileprivate func drainPeak() -> AudioMeterSample? {
        lock.withLock {
            guard let oldest = pending.first else { return nil }
            let peak = pending.max { $0.level < $1.level } ?? oldest
            coalescedCount += pending.count - 1
            pending.removeAll(keepingCapacity: true)
            return AudioMeterSample(level: peak.level, emittedAt: oldest.emittedAt)
        }
    }

    fileprivate func noteRendered(lagMilliseconds: Double) {
        lock.withLock {
            renderedCount += 1
            maximumDeliveryLagMilliseconds = max(maximumDeliveryLagMilliseconds, lagMilliseconds)
        }
    }

    func statistics() -> AudioMeterStatistics {
        lock.withLock {
            AudioMeterStatistics(receivedCount: receivedCount,
                                 renderedCount: renderedCount,
                                 coalescedCount: coalescedCount,
                                 maximumDeliveryLagMilliseconds: maximumDeliveryLagMilliseconds)
        }
    }
}

@MainActor
final class AudioMeterState: ObservableObject {
    /// One bar enters the waveform per tick, on a grid anchored at `start()`.
    ///
    /// The previous pacer re-anchored itself to the moment each frame actually
    /// rendered and only woke when a sample arrived, so it drifted against both
    /// the audio clock and the display clock. It is a grid now, and a tick that
    /// runs late is absorbed rather than pushed onto the next one.
    nonisolated static let frameInterval = Duration.microseconds(33_333)
    nonisolated static let sampleInterval: TimeInterval = 1.0 / 30.0

    /// Long enough to fill the widest waveform viewport the overlay draws.
    /// The compact pill needs 37 bars at its 4.5 pt pitch and the wide one 45.
    nonisolated static let historyLength = 64

    /// The grid point after `tick`.
    ///
    /// The previous pacer re-anchored on every tick, to the moment the frame
    /// actually rendered, so each wake-up's scheduling slop was added to the
    /// next interval and the cadence walked away from 30 Hz. Anchoring to the
    /// grid absorbs that slop; only a tick late enough to have missed its own
    /// successor re-anchors, and then it re-anchors once rather than firing a
    /// burst of catch-up ticks.
    nonisolated static func nextGridPoint(after tick: ContinuousClock.Instant,
                                          now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        let next = tick.advanced(by: frameInterval)
        return next > now ? next : now.advanced(by: frameInterval)
    }

    @Published private(set) var levels = [Float](repeating: 0, count: historyLength)

    /// When the newest bar entered. The waveform derives its horizontal offset
    /// from `now - lastSampleAt` instead of from tick arrivals, so a late tick
    /// shows up as a bar whose height lands late, never as a jump in the scroll.
    @Published private(set) var lastSampleAt = Date()

    private var consumerTask: Task<Void, Never>?
    private var sink: AudioLevelSink?
    private var smoother = AudioLevelSmoother()
    private var generation = 0

    @discardableResult
    func start() -> AudioLevelSink {
        stop(resetLevels: true)
        smoother.reset()
        generation += 1
        let generation = generation
        let sink = AudioLevelSink()
        self.sink = sink
        lastSampleAt = Date()
        consumerTask = Task { @MainActor [weak self, sink] in
            let clock = ContinuousClock()
            var nextTick = clock.now.advanced(by: Self.frameInterval)
            while !Task.isCancelled {
                do { try await clock.sleep(until: nextTick) } catch { return }
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                let now = clock.now
                nextTick = Self.nextGridPoint(after: nextTick, now: now)

                // Silence still has to scroll, so a tick with nothing pending
                // renders a zero bar rather than skipping.
                let sample = sink.drainPeak()
                if let sample {
                    sink.noteRendered(lagMilliseconds: Self.milliseconds(sample.emittedAt.duration(to: now)))
                }
                self.levels.removeFirst()
                self.levels.append(self.smoother.update(sample?.level ?? 0))
                self.lastSampleAt = Date()
            }
        }
        return sink
    }

    @discardableResult
    func stop(resetLevels: Bool = true) -> AudioMeterStatistics {
        generation += 1
        let statistics = sink?.statistics()
            ?? AudioMeterStatistics(receivedCount: 0, renderedCount: 0,
                                    coalescedCount: 0, maximumDeliveryLagMilliseconds: 0)
        consumerTask?.cancel()
        consumerTask = nil
        sink = nil
        smoother.reset()
        if resetLevels { levels = [Float](repeating: 0, count: Self.historyLength) }
        return statistics
    }

    func statistics() -> AudioMeterStatistics {
        sink?.statistics()
            ?? AudioMeterStatistics(receivedCount: 0, renderedCount: 0,
                                    coalescedCount: 0, maximumDeliveryLagMilliseconds: 0)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
