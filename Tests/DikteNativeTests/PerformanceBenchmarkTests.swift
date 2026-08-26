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
        let resourceStart = processResources()

        let requestedThreads = ProcessInfo.processInfo.environment["DIKTE_BENCHMARK_THREADS"]
            .map { value in value.split(separator: ",").compactMap { Int32($0) } } ?? [4, 6, 8]
        let iterations = max(1, Int(ProcessInfo.processInfo.environment["DIKTE_BENCHMARK_ITERATIONS"] ?? "1") ?? 1)
        for threadCount in requestedThreads {
            var wallValues: [Double] = []
            var cpuValues: [Double] = []
            for iteration in 1...iterations {
                let wallStart = DispatchTime.now().uptimeNanoseconds
                let cpuStart = processCPUTime()
                let result = try await engine.transcribe(samples: samples, language: .turkish,
                                                         threadCount: threadCount)
                let wallMS = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000
                let cpuMS = (processCPUTime() - cpuStart) * 1_000
                XCTAssertFalse(result.text.isEmpty)
                wallValues.append(wallMS); cpuValues.append(cpuMS)
                print(String(format: "DIKTE_BENCH threads=%d iteration=%d wall_ms=%.0f cpu_ms=%.0f",
                             threadCount, iteration, wallMS, cpuMS))
            }
            let sortedWall = wallValues.sorted()
            let sortedCPU = cpuValues.sorted()
            let median = sortedWall[sortedWall.count / 2]
            let p95Index = min(sortedWall.count - 1, Int(ceil(Double(sortedWall.count) * 0.95)) - 1)
            print(String(format: "DIKTE_BENCH_SUMMARY threads=%d iterations=%d median_wall_ms=%.0f p95_wall_ms=%.0f median_cpu_ms=%.0f",
                         threadCount, iterations, median, sortedWall[p95Index], sortedCPU[sortedCPU.count / 2]))
        }
        if ProcessInfo.processInfo.environment["DIKTE_BENCHMARK_SOAK"] == "1" {
            let resourceEnd = processResources()
            let residentGrowth = max(0, resourceEnd.residentBytes - resourceStart.residentBytes)
            let threadGrowth = resourceEnd.threadCount - resourceStart.threadCount
            print("DIKTE_SOAK resident_growth=\(residentGrowth) thread_growth=\(threadGrowth)")
            XCTAssertLessThanOrEqual(residentGrowth, 50 * 1_024 * 1_024)
            XCTAssertLessThanOrEqual(threadGrowth, 2)
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

    private func processResources() -> (residentBytes: Int64, threadCount: Int) {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let result = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, size)
        guard result == size else { return (0, 0) }
        return (Int64(task.pti_resident_size), Int(task.pti_threadnum))
    }
}
