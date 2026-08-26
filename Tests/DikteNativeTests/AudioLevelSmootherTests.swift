import XCTest
@testable import DikteNative

final class AudioLevelSmootherTests: XCTestCase {
    func testAttackAndReleaseAreMonotonicAndBounded() {
        var smoother = AudioLevelSmoother()
        var rising: [Float] = []
        for _ in 0..<8 { rising.append(smoother.update(1)) }

        XCTAssertEqual(rising, rising.sorted())
        XCTAssertTrue(rising.allSatisfy { (0...1).contains($0) })

        var falling: [Float] = []
        for _ in 0..<8 { falling.append(smoother.update(0)) }
        XCTAssertEqual(falling, falling.sorted(by: >))
        XCTAssertTrue(falling.allSatisfy { (0...1).contains($0) })
    }

    func testSilenceSettlesExactlyAtZero() {
        var smoother = AudioLevelSmoother()
        _ = smoother.update(0.8)
        for _ in 0..<30 { _ = smoother.update(0) }

        XCTAssertEqual(smoother.value, 0)
    }

    func testInputIsClampedAndNonFiniteValuesAreSafe() {
        var smoother = AudioLevelSmoother()
        XCTAssertEqual(smoother.update(.infinity), 0)
        XCTAssertEqual(smoother.update(.nan), 0)
        XCTAssertEqual(smoother.update(-5), 0)
        XCTAssertLessThanOrEqual(smoother.update(5), 1)
    }

    func testResetDropsPreviousRecordingState() {
        var smoother = AudioLevelSmoother()
        XCTAssertGreaterThan(smoother.update(1), 0)
        smoother.reset()
        XCTAssertEqual(smoother.value, 0)
    }
}
