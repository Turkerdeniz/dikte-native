import Foundation

enum RouteDestination: Equatable, Sendable {
    case local
    case codex
}

enum RoutePolicy {
    static func destination(for mode: CaptureMode, duration: TimeInterval, threshold: TimeInterval) -> RouteDestination {
        switch mode {
        case .general:
            return shouldUseCodex(duration: duration, threshold: threshold) ? .codex : .local
        case .coding:
            return .codex
        }
    }

    static func shouldUseCodex(duration: TimeInterval, threshold: TimeInterval) -> Bool {
        threshold > 0 && duration > threshold
    }
}
