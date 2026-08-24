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
        let silence = [Float](repeating: 0, count: 8_000)
        let voice = [Float](repeating: 0.05, count: 8_000)
        let capture = AudioCapture(samples: silence + voice + silence, sampleRate: 16_000, duration: 1.5)
        let result = AudioPreprocessor.prepare(capture)
        XCTAssertGreaterThan(result.samples.count, voice.count)
        XCTAssertLessThan(result.samples.count, capture.samples.count)
        XCTAssertEqual(result.voicedDuration, 0.5, accuracy: 0.03)
    }
}
