import Foundation
import XCTest
@testable import DikteNative

private final class LevelBox: @unchecked Sendable { var value: Float = -1 }

/// Exercises the real AVAudioEngine + Voice Processing I/O capture path against
/// live hardware. Gated like the 547 MB model test: it needs an actual
/// microphone and Microphone permission already granted to the test host, so
/// it does not run by default or in CI.
@MainActor
final class NoiseSuppressionCaptureTests: XCTestCase {
    func testVoiceProcessingCaptureDeliversRealSixteenKilohertzMonoAudio() async throws {
        guard ProcessInfo.processInfo.environment["DIKTE_TEST_NOISE_SUPPRESSION"] == "1" else {
            throw XCTSkip("Set DIKTE_TEST_NOISE_SUPPRESSION=1 to run this against the real microphone.")
        }
        let recorder = AudioRecorder()
        var firstSampleReceived = false
        let level = LevelBox()
        try await recorder.start(noiseSuppression: true) {
            firstSampleReceived = true
        } onLevel: { value in
            level.value = value
        }
        try await Task.sleep(for: .seconds(2))
        let capture = await recorder.stop()

        XCTAssertTrue(firstSampleReceived, "onFirstSample callback never fired")
        XCTAssertGreaterThanOrEqual(level.value, 0, "no level callback observed")
        XCTAssertEqual(capture.sampleRate, 16_000)
        XCTAssertGreaterThan(capture.samples.count, 16_000, "expected roughly 2 seconds of 16 kHz audio")
        XCTAssertEqual(capture.diagnostics.callbackCount > 0, true)
        XCTAssertTrue(capture.diagnostics.inputFormat.contains("Voice Processing"))
        XCTAssertEqual(capture.diagnostics.conversionErrors, 0)
    }
}
