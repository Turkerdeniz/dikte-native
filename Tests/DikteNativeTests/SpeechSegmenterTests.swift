import XCTest
@testable import DikteNative

final class SpeechSegmenterTests: XCTestCase {
    func testVADCentisecondsConvertToSamples() {
        XCTAssertEqual(SpeechSegmenter.sampleIndex(centiseconds: 29, rounding: .down, limit: 16_000), 4_640)
        XCTAssertEqual(SpeechSegmenter.sampleIndex(centiseconds: 221, rounding: .up, limit: 100_000), 35_360)
        XCTAssertEqual(SpeechSegmenter.sampleIndex(centiseconds: 900, rounding: .up, limit: 16_000), 16_000)
    }

    func testLegacyAudioDiagnosticsDecodeWithVADDefaults() throws {
        let legacy = #"{"deviceName":"MacBook Pro Mikrofonu","callbackCount":42}"#.data(using: .utf8)!
        let diagnostics = try JSONDecoder().decode(AudioDiagnostics.self, from: legacy)
        XCTAssertEqual(diagnostics.deviceName, "MacBook Pro Mikrofonu")
        XCTAssertEqual(diagnostics.callbackCount, 42)
        XCTAssertEqual(diagnostics.vadSegmentCount, 0)
        XCTAssertNil(diagnostics.vadFallbackReason)
    }

    func testMergesPaddedOverlappingRegions() {
        let regions = [
            SpeechRegion(startSample: 100, endSample: 600),
            SpeechRegion(startSample: 500, endSample: 900),
            SpeechRegion(startSample: 1_200, endSample: 1_500)
        ]

        XCTAssertEqual(SpeechChunkBuilder.mergeOverlaps(regions), [
            SpeechRegion(startSample: 100, endSample: 900),
            SpeechRegion(startSample: 1_200, endSample: 1_500)
        ])
    }

    func testRemovesLongPauseAndInsertsShortSeparator() {
        let samples = [Float](repeating: 0.25, count: 20 * SpeechChunkBuilder.sampleRate)
        let regions = [
            SpeechRegion(startSample: 0, endSample: 2 * SpeechChunkBuilder.sampleRate),
            SpeechRegion(startSample: 12 * SpeechChunkBuilder.sampleRate,
                         endSample: 14 * SpeechChunkBuilder.sampleRate)
        ]

        let chunks = SpeechChunkBuilder.makeChunks(samples: samples, regions: regions)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].samples.count, 4 * SpeechChunkBuilder.sampleRate + SpeechChunkBuilder.separatorSamples)
        XCTAssertEqual(chunks[0].sourceStartSample, 0)
        XCTAssertEqual(chunks[0].sourceEndSample, 14 * SpeechChunkBuilder.sampleRate)
        XCTAssertEqual(chunks[0].speechSampleCount, 4 * SpeechChunkBuilder.sampleRate)
        XCTAssertTrue(chunks[0].samples[2 * SpeechChunkBuilder.sampleRate..<(2 * SpeechChunkBuilder.sampleRate + SpeechChunkBuilder.separatorSamples)]
            .allSatisfy { $0 == 0 })
    }

    func testContinuousSpeechIsSplitIntoAtMostTwentySecondChunks() {
        let count = 45 * SpeechChunkBuilder.sampleRate
        let samples = [Float](repeating: 0.1, count: count)
        let regions = [SpeechRegion(startSample: 0, endSample: count)]

        let chunks = SpeechChunkBuilder.makeChunks(samples: samples, regions: regions)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.samples.count <= SpeechChunkBuilder.maximumChunkSamples })
    }

    func testTranscriptAssemblerRemovesOverlapAtChunkBoundary() {
        let result = TranscriptAssembler.join([
            "Bu uzun kaydın ilk kısmıdır ve burada devam ediyor.",
            "burada devam ediyor. İkinci bölüm de korunuyor."
        ])

        XCTAssertEqual(result, "Bu uzun kaydın ilk kısmıdır ve burada devam ediyor. İkinci bölüm de korunuyor.")
    }

    @MainActor
    func testBundledVADModelHasPinnedIdentity() async throws {
        XCTAssertEqual(VADModelStore.expectedSHA256.count, 64)
        let url = try await VADModelStore().modelURL()
        XCTAssertEqual(url.lastPathComponent, "ggml-silero-v6.2.0.bin")
    }

    @MainActor
    func testBundledVADModelResolvesFromStandardMacAppResources() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let resources = temporary.appendingPathComponent("Dikte.app/Contents/Resources", isDirectory: true)
        let expected = resources
            .appendingPathComponent("DikteNative_DikteNative.bundle", isDirectory: true)
            .appendingPathComponent("ggml-silero-v6.2.0.bin")
        try FileManager.default.createDirectory(
            at: expected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: expected)

        XCTAssertEqual(VADModelStore.locateBundledModel(searchRoots: [resources]), expected)
    }

    @MainActor
    func testBundledVADModelLoadsAndRejectsSilence() async throws {
        let url = try await VADModelStore().modelURL()
        let segmenter = SpeechSegmenter()
        let result = try await segmenter.segment(samples: [Float](repeating: 0, count: 16_000), modelURL: url)
        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(result.segmentCount, 0)
        await segmenter.unload()
    }
}
