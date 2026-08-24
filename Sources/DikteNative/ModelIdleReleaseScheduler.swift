import Foundation

@MainActor
final class ModelIdleReleaseScheduler {
    private var task: Task<Void, Never>?

    func schedule(after seconds: TimeInterval,
                  operation: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            operation()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
