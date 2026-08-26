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

/// A thread-safe, single-slot handoff from CoreAudio to the presentation layer.
/// The callback only replaces the newest value and signals the consumer; it never
/// creates an unbounded queue of MainActor jobs.
final class AudioLevelSink: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<Void>.Continuation
    let signals: AsyncStream<Void>
    private var latest: AudioMeterSample?
    private var receivedCount = 0
    private var renderedCount = 0
    private var coalescedCount = 0
    private var maximumDeliveryLagMilliseconds = 0.0

    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = pair.stream
        continuation = pair.continuation
    }

    func yield(_ level: Float) {
        let sample = AudioMeterSample(level: level.isFinite ? min(1, max(0, level)) : 0,
                                      emittedAt: ContinuousClock.now)
        lock.withLock {
            receivedCount += 1
            if latest != nil { coalescedCount += 1 }
            latest = sample
        }
        _ = continuation.yield(())
    }

    fileprivate func takeLatest() -> AudioMeterSample? {
        lock.withLock {
            defer { latest = nil }
            return latest
        }
    }

    fileprivate func noteRendered(lagMilliseconds: Double) {
        lock.withLock {
            renderedCount += 1
            maximumDeliveryLagMilliseconds = max(maximumDeliveryLagMilliseconds, lagMilliseconds)
        }
    }

    func finish() { continuation.finish() }

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
    static let frameInterval = Duration.milliseconds(34)

    @Published private(set) var levels = [Float](repeating: 0, count: 34)
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
        consumerTask = Task { @MainActor [weak self, sink] in
            let clock = ContinuousClock()
            var nextFrame = clock.now
            for await _ in sink.signals {
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                let now = clock.now
                if now < nextFrame {
                    do { try await clock.sleep(until: nextFrame) }
                    catch { return }
                }
                guard !Task.isCancelled, generation == self.generation,
                      let sample = sink.takeLatest() else { continue }
                let renderedAt = clock.now
                let lag = sample.emittedAt.duration(to: renderedAt)
                sink.noteRendered(lagMilliseconds: Self.milliseconds(lag))
                self.levels.removeFirst()
                self.levels.append(self.smoother.update(sample.level))
                nextFrame = renderedAt.advanced(by: Self.frameInterval)
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
        sink?.finish()
        consumerTask?.cancel()
        consumerTask = nil
        sink = nil
        smoother.reset()
        if resetLevels { levels = [Float](repeating: 0, count: 34) }
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
