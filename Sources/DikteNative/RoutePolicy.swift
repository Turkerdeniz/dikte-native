import Foundation

enum RoutePolicy {
    static func shouldUseCodex(duration: TimeInterval, threshold: TimeInterval) -> Bool {
        threshold > 0 && duration > threshold
    }
}
