import AVFoundation
import XCTest
@testable import DikteNative

/// Runs the real model over a real recording and checks that per-word certainty
/// actually comes out of it. The unit tests above cover the regrouping logic on
/// synthetic pieces; only this shows that whisper.cpp hands back token text and
/// probabilities that line up with the transcript. Gated like the other
/// model-backed tests: it needs the 547 MB model and a WAV to point at.
final class TranscriptWordRuntimeTests: XCTestCase {
    func testRealTranscriptionReportsPerWordCertainty() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIKTE_TEST_WAV"] else {
            throw XCTSkip("Set DIKTE_TEST_WAV to a 16 kHz mono WAV to run this.")
        }
        let modelURL = AppPaths.model
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("Whisper model is not downloaded.")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            return XCTFail("could not allocate a buffer for \(path)")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return XCTFail("no float samples") }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))

        let engine = WhisperEngine()
        try await engine.load(modelURL: modelURL)
        let transcript = try await engine.transcribe(samples: samples, language: .turkish)
        await engine.unload()

        XCTAssertFalse(transcript.text.isEmpty)
        XCTAssertFalse(transcript.words.isEmpty, "no per-word certainty was produced")
        // The words must be the transcript's own words, not stray fragments.
        let joined = transcript.words.map(\.text).joined(separator: " ")
        let expected = transcript.text.split(whereSeparator: \.isWhitespace).count
        XCTAssertEqual(transcript.words.count, expected,
                       "word count \(transcript.words.count) does not match the transcript's \(expected): \(joined)")
        for word in transcript.words {
            XCTAssertGreaterThan(word.probability, 0)
            XCTAssertLessThanOrEqual(word.probability, 1)
        }
    }
}
