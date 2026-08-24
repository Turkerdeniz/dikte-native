import Foundation

enum MemoryPressureLevel: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case critical
}

enum ModelMemoryPressureAction: Equatable, Sendable {
    case none
    case releaseNow
    case deferRelease
}

enum MemoryPressurePolicy {
    static func action(for level: MemoryPressureLevel, phase: AppPhase) -> ModelMemoryPressureAction {
        guard level != .normal else { return .none }
        if case .processing = phase { return .deferRelease }
        return .releaseNow
    }

    static func shouldReleaseOnReturnToIdle(pending: Bool, level: MemoryPressureLevel) -> Bool {
        pending || level != .normal
    }
}

/// Owns the Dispatch memory-pressure source without ever retaining or invoking AppModel.
/// The dispatch callback only yields a Sendable value; AppModel consumes `events` on MainActor.
final class MemoryPressureMonitor: @unchecked Sendable {
    let events: AsyncStream<MemoryPressureLevel>

    private let continuation: AsyncStream<MemoryPressureLevel>.Continuation
    private let lock = NSLock()
    private var source: DispatchSourceMemoryPressure?
    private var isCancelled = false

    init(startSystemSource: Bool = true) {
        let pair = AsyncStream<MemoryPressureLevel>.makeStream(
            of: MemoryPressureLevel.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        events = pair.stream
        continuation = pair.continuation

        guard startSystemSource else { return }
        let dispatchSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .global(qos: .utility)
        )
        source = dispatchSource
        dispatchSource.setEventHandler { [weak self, weak dispatchSource] in
            guard let self, let data = dispatchSource?.data else { return }
            self.emit(Self.level(for: data))
        }
        dispatchSource.resume()
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let source = source
        self.source = nil
        lock.unlock()

        source?.setEventHandler {}
        source?.cancel()
        continuation.finish()
    }

    func emitForTesting(_ level: MemoryPressureLevel) {
        emit(level)
    }

    private func emit(_ level: MemoryPressureLevel) {
        lock.lock()
        let shouldYield = !isCancelled
        lock.unlock()
        guard shouldYield else { return }
        continuation.yield(level)
    }

    private static func level(for data: DispatchSource.MemoryPressureEvent) -> MemoryPressureLevel {
        if data.contains(.critical) { return .critical }
        if data.contains(.warning) { return .warning }
        return .normal
    }

    deinit {
        cancel()
    }
}
