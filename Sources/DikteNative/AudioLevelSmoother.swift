import Foundation

struct AudioLevelSmoother: Sendable {
    static let attack: Float = 0.55
    static let release: Float = 0.25
    static let silenceFloor: Float = 0.01

    private(set) var value: Float = 0

    mutating func update(_ input: Float) -> Float {
        let target = min(1, max(0, input.isFinite ? input : 0))
        let coefficient = target > value ? Self.attack : Self.release
        value += (target - value) * coefficient
        if value < Self.silenceFloor { value = 0 }
        value = min(1, max(0, value))
        return value
    }

    mutating func reset() { value = 0 }
}
