import Foundation

enum RouteDestination: Equatable, Sendable {
    case local
    case codex
}

enum RoutePolicy {
    /// Below this mean token probability the transcript is treated as needing
    /// repair. Measured against the user's own history: recordings under the
    /// duration threshold sit around 0.84 when they came out clean, and the ones
    /// that read as garbled cluster well below this.
    static let repairConfidenceThreshold: Float = 0.75
    /// Confidence over a handful of tokens is too noisy to act on, and sending a
    /// two-word "Teşekkürler." to Codex costs the user a wait for nothing. This
    /// is deliberately stricter than `TranscriptionPolicy`'s own minimum, because
    /// that one only downgrades a result while this one takes the slow path.
    static let minimumTokensForRepair = 8

    /// Duration used to be the only signal, which meant more than half of the
    /// recordings in practice — median under seven seconds — never got any
    /// repair at all, however badly they came out. Duration is a proxy for "this
    /// is worth the wait"; poor confidence is direct evidence of "this needs the
    /// help", so either now routes to Codex.
    static func destination(for mode: CaptureMode, duration: TimeInterval, threshold: TimeInterval,
                            confidence: Float? = nil, tokenCount: Int = 0) -> RouteDestination {
        switch mode {
        case .general:
            if shouldUseCodex(duration: duration, threshold: threshold) { return .codex }
            return needsRepair(confidence: confidence, tokenCount: tokenCount) ? .codex : .local
        case .coding:
            return .codex
        }
    }

    static func shouldUseCodex(duration: TimeInterval, threshold: TimeInterval) -> Bool {
        threshold > 0 && duration > threshold
    }

    static func needsRepair(confidence: Float?, tokenCount: Int) -> Bool {
        guard let confidence, tokenCount >= minimumTokensForRepair else { return false }
        return confidence < repairConfidenceThreshold
    }
}
