import XCTest
@testable import DikteNative

final class AudioResamplerTests: XCTestCase {
    func testResamples48kHzTo16kHz() {
        let source = (0..<48_000).map { Float($0) / 48_000 }
        let capture = AudioCapture(samples: source, sampleRate: 48_000, duration: 1)

        let result = AudioResampler.to16kHz(capture)

        XCTAssertEqual(result.count, 16_000)
        XCTAssertEqual(result[1], source[3], accuracy: 0.000_001)
        XCTAssertEqual(result[15_999], source[47_997], accuracy: 0.000_001)
    }

    func testKeeps16kHzSamplesUnchanged() {
        let source: [Float] = [0, 0.25, -0.5, 1]
        let capture = AudioCapture(samples: source, sampleRate: 16_000, duration: 0.001)

        XCTAssertEqual(AudioResampler.to16kHz(capture), source)
    }

    func testRejectsEmptyCapture() {
        let capture = AudioCapture(samples: [], sampleRate: 48_000, duration: 1)

        XCTAssertTrue(AudioResampler.to16kHz(capture).isEmpty)
    }

    func testPreprocessorRejectsSilence() {
        let capture = AudioCapture(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000, duration: 1)
        let result = AudioPreprocessor.prepare(capture)
        XCTAssertTrue(result.samples.isEmpty)
        XCTAssertEqual(result.voicedDuration, 0)
    }

    func testPreprocessorTrimsSilenceAndKeepsVoice() {
        // A tone inside the speech band, not a constant offset: the preprocessor
        // now high-passes its input, and a DC level is exactly what that removes.
        let silence = [Float](repeating: 0, count: 8_000)
        let capture = AudioCapture(samples: silence + Self.tone(hertz: 200, amplitude: 0.05, count: 8_000) + silence,
                                   sampleRate: 16_000, duration: 1.5)
        let result = AudioPreprocessor.prepare(capture)
        XCTAssertGreaterThan(result.samples.count, 8_000)
        XCTAssertLessThan(result.samples.count, capture.samples.count)
        XCTAssertEqual(result.voicedDuration, 0.5, accuracy: 0.03)
    }

    // MARK: - High-pass

    func testHighPassRemovesAConstantOffset() {
        let filtered = AudioPreprocessor.highPassed([Float](repeating: 0.5, count: 16_000), sampleRate: 16_000)
        // Only the step at the very start survives; the steady level does not.
        let tail = filtered.suffix(8_000)
        XCTAssertLessThan(tail.map(abs).max() ?? 1, 0.001)
    }

    func testHighPassKeepsSpeechBandContent() {
        let tone = Self.tone(hertz: 300, amplitude: 0.5, count: 16_000)
        let filtered = AudioPreprocessor.highPassed(tone, sampleRate: 16_000)
        let originalPeak = tone.suffix(8_000).map(abs).max() ?? 0
        let filteredPeak = filtered.suffix(8_000).map(abs).max() ?? 0
        XCTAssertGreaterThan(filteredPeak, originalPeak * 0.9)
    }

    func testHighPassAttenuatesRumbleFarMoreThanSpeech() {
        let rumble = AudioPreprocessor.highPassed(Self.tone(hertz: 25, amplitude: 0.5, count: 16_000),
                                                  sampleRate: 16_000)
        let speech = AudioPreprocessor.highPassed(Self.tone(hertz: 300, amplitude: 0.5, count: 16_000),
                                                  sampleRate: 16_000)
        let rumblePeak = rumble.suffix(8_000).map(abs).max() ?? 0
        let speechPeak = speech.suffix(8_000).map(abs).max() ?? 0
        XCTAssertLessThan(rumblePeak, speechPeak * 0.2)
    }

    func testHighPassLeavesTooShortABufferAlone() {
        XCTAssertEqual(AudioPreprocessor.highPassed([0.1, 0.2], sampleRate: 16_000), [0.1, 0.2])
    }

    // MARK: - Adaptive threshold

    func testQuietRoomKeepsTheFixedThreshold() {
        let levels = [Float](repeating: 0.0005, count: 40) + [Float](repeating: 0.05, count: 60)
        let profile = AudioPreprocessor.noiseProfile(forFrameLevels: levels)
        XCTAssertEqual(profile.threshold, AudioPreprocessor.speechThreshold)
    }

    func testNoisyRoomRaisesTheThresholdAboveTheNoiseFloor() {
        // A room whose noise floor already sits above the fixed 0.008: with the
        // old absolute threshold every frame counted as speech.
        let levels = [Float](repeating: 0.02, count: 50) + [Float](repeating: 0.30, count: 50)
        let profile = AudioPreprocessor.noiseProfile(forFrameLevels: levels)
        XCTAssertGreaterThan(profile.threshold, AudioPreprocessor.speechThreshold)
        XCTAssertGreaterThan(profile.threshold, profile.noiseFloor)
        XCTAssertLessThan(profile.threshold, 0.30)
    }

    func testThresholdNeverClimbsIntoTheSpeechItself() {
        let levels = [Float](repeating: 0.10, count: 50) + [Float](repeating: 0.40, count: 50)
        let profile = AudioPreprocessor.noiseProfile(forFrameLevels: levels)
        XCTAssertLessThanOrEqual(profile.threshold, 0.40 * AudioPreprocessor.speechLevelCeilingShare)
    }

    func testUniformLevelsFallBackToTheFixedThreshold() {
        // Nothing to adapt to: no separation between the quiet and loud ends.
        let profile = AudioPreprocessor.noiseProfile(forFrameLevels: [Float](repeating: 0.05, count: 100))
        XCTAssertEqual(profile.threshold, AudioPreprocessor.speechThreshold)
    }

    func testNoisyRoomStillTrimsToTheLoudRegion() {
        let noise = Self.tone(hertz: 400, amplitude: 0.03, count: 8_000)
        let speech = Self.tone(hertz: 400, amplitude: 0.40, count: 8_000)
        let capture = AudioCapture(samples: noise + speech + noise, sampleRate: 16_000, duration: 1.5)
        let result = AudioPreprocessor.prepare(capture)
        XCTAssertLessThan(result.samples.count, capture.samples.count,
                          "the noisy stretches must still be trimmed away")
        XCTAssertEqual(result.voicedDuration, 0.5, accuracy: 0.05)
    }

    private static func tone(hertz: Double, amplitude: Float, count: Int) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * Double.pi * hertz * Double($0) / 16_000)) }
    }
}
