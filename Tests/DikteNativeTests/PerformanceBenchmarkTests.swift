import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import DikteNative

@MainActor
final class PerformanceBenchmarkTests: XCTestCase {
    func testWhisperThreadSweepWhenFixtureIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIKTE_BENCHMARK_AUDIO"] else {
            throw XCTSkip("Set DIKTE_BENCHMARK_AUDIO to run the 4/6/8 thread sweep.")
        }
        let samples = try loadMonoSamples(URL(fileURLWithPath: path))
        let engine = WhisperEngine()
        try await engine.load(modelURL: AppPaths.model)
        _ = try await engine.transcribe(samples: samples, language: .turkish, threadCount: 8)

        for threadCount: Int32 in [4, 6, 8] {
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let cpuStart = processCPUTime()
            let result = try await engine.transcribe(samples: samples, language: .turkish,
                                                     threadCount: threadCount)
            let wallMS = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000
            let cpuMS = (processCPUTime() - cpuStart) * 1_000
            XCTAssertFalse(result.text.isEmpty)
            print(String(format: "DIKTE_BENCH threads=%d wall_ms=%.0f cpu_ms=%.0f text=%@",
                         threadCount, wallMS, cpuMS, result.text))
        }
        await engine.unload()
    }

    private func loadMonoSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw DikteError.message("Benchmark ses tamponu oluşturulamadı.")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw DikteError.message("Benchmark ses kanalı okunamadı.")
        }
        let values = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return AudioPreprocessor.resample(values, from: format.sampleRate, to: AudioPreprocessor.targetRate)
    }

    private func processCPUTime() -> Double {
        var value = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }
}
