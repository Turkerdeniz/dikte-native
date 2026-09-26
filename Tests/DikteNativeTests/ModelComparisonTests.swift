import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import DikteNative

/// Runs saved diagnostic captures through one Whisper model the way the app
/// does — high-pass, Silero VAD, per-chunk decode with the learned prompt
/// terms — so two models can be compared on the same audio. Run it once per
/// model, each in its own `swift test` process, because peak memory is read
/// from the process's lifetime maximum.
///
/// Transcripts go only to `DIKTE_COMPARE_OUT`, which must live outside the
/// repository: they are the user's own speech. Standard output carries numbers.
@MainActor
final class ModelComparisonTests: XCTestCase {
    func testTranscribeCapturesWithGivenModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["DIKTE_COMPARE_MODEL"],
              let capturesPath = environment["DIKTE_COMPARE_CAPTURES"],
              let outputPath = environment["DIKTE_COMPARE_OUT"] else {
            throw XCTSkip("Set DIKTE_COMPARE_MODEL, DIKTE_COMPARE_CAPTURES and DIKTE_COMPARE_OUT to compare models.")
        }
        let iterations = max(1, Int(environment["DIKTE_COMPARE_ITERATIONS"] ?? "3") ?? 3)
        let captures = try captureDirectories(at: URL(fileURLWithPath: capturesPath))
        XCTAssertFalse(captures.isEmpty, "no capture with audio.wav under \(capturesPath)")

        let modelURL = URL(fileURLWithPath: modelPath)
        let promptTerms = CorrectionStore().promptTerms
        let vadURL = try await VADModelStore().modelURL()
        let segmenter = SpeechSegmenter()
        let engine = WhisperEngine()

        let footprintBeforeLoad = Self.footprint().current
        let loadStarted = DispatchTime.now().uptimeNanoseconds
        try await engine.load(modelURL: modelURL)
        let loadMilliseconds = Self.milliseconds(since: loadStarted)
        let footprintAfterLoad = Self.footprint().current

        var rows: [[String: Any]] = []
        for capture in captures {
            let raw = try loadMonoSamples(capture.appendingPathComponent("audio.wav"))
            let samples = AudioPreprocessor.highPassed(raw, sampleRate: AudioPreprocessor.targetRate)
            let segmentation = try await segmenter.segment(samples: samples, modelURL: vadURL)
            let chunks = segmentation.chunks.isEmpty
                ? [SpeechChunk(samples: samples, sourceStartSample: 0, sourceEndSample: samples.count,
                               speechSampleCount: samples.count)]
                : segmentation.chunks

            var wallValues: [Double] = []
            var text = ""
            var confidence: Float = 0
            var retryWouldRun = false
            for _ in 1...iterations {
                let started = DispatchTime.now().uptimeNanoseconds
                var parts: [WhisperTranscript] = []
                for chunk in chunks {
                    parts.append(try await engine.transcribe(samples: chunk.samples, language: .turkish,
                                                             promptTerms: promptTerms))
                }
                wallValues.append(Self.milliseconds(since: started))
                text = TranscriptAssembler.join(parts.map(\.text))
                let tokens = parts.reduce(0) { $0 + $1.tokenCount }
                confidence = tokens > 0
                    ? parts.reduce(0) { $0 + $1.meanTokenProbability * Float($1.tokenCount) } / Float(tokens) : 0
                retryWouldRun = zip(parts, chunks).contains {
                    ChunkAcceptancePolicy.issue(for: $0, speechDuration: $1.speechDuration) != nil
                }
            }
            let median = wallValues.sorted()[wallValues.count / 2]
            let audioSeconds = Double(raw.count) / AudioPreprocessor.targetRate
            print(String(format: "DIKTE_COMPARE capture=%@ audio_s=%.1f chunks=%d median_wall_ms=%.0f confidence=%.3f",
                         capture.lastPathComponent.prefix(8) as CVarArg, audioSeconds, chunks.count, median, confidence))
            rows.append([
                "capture": capture.lastPathComponent, "audioSeconds": audioSeconds,
                "chunks": chunks.count, "wallMilliseconds": wallValues, "medianWallMilliseconds": median,
                "confidence": confidence, "retryWouldRun": retryWouldRun, "text": text
            ])
        }

        let footprint = Self.footprint()
        let summary: [String: Any] = [
            "model": modelURL.lastPathComponent, "iterations": iterations,
            "loadMilliseconds": loadMilliseconds,
            "footprintBeforeLoadBytes": footprintBeforeLoad, "footprintAfterLoadBytes": footprintAfterLoad,
            "peakFootprintBytes": footprint.peak, "promptTermCount": promptTerms.count, "captures": rows
        ]
        await engine.unload()
        print(String(format: "DIKTE_COMPARE_SUMMARY model=%@ load_ms=%.0f loaded_mb=%.0f peak_mb=%.0f",
                     modelURL.lastPathComponent, loadMilliseconds,
                     Double(footprintAfterLoad) / 1_048_576, Double(footprint.peak) / 1_048_576))

        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    private func captureDirectories(at root: URL) throws -> [URL] {
        let manager = FileManager.default
        if manager.fileExists(atPath: root.appendingPathComponent("audio.wav").path) { return [root] }
        return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension != "part" && manager.fileExists(atPath: $0.appendingPathComponent("audio.wav").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func loadMonoSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw DikteError.message("Karşılaştırma ses tamponu oluşturulamadı.")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw DikteError.message("Karşılaştırma ses kanalı okunamadı.")
        }
        let values = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return AudioPreprocessor.resample(values, from: file.processingFormat.sampleRate,
                                          to: AudioPreprocessor.targetRate)
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// Current and lifetime-maximum physical footprint. On Apple Silicon the
    /// Metal buffers holding the weights are counted here too.
    private static func footprint() -> (current: UInt64, peak: UInt64) {
        var usage = rusage_info_v4()
        let result: Int32 = withUnsafeMutableBytes(of: &usage) { bytes in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return proc_pid_rusage(getpid(), RUSAGE_INFO_V4, baseAddress.assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard result == 0 else { return (0, 0) }
        return (usage.ri_phys_footprint, usage.ri_lifetime_max_phys_footprint)
    }
}
