import Foundation
import XCTest
@testable import DikteNative

@MainActor
final class WhisperDiagnosticStoreTests: XCTestCase {
    func testOneShotArmIgnoresMicrophoneTestAndConsumesOneNormalRecording() {
        var arm = OneShotDiagnosticCaptureArm()
        arm.toggle()

        XCTAssertFalse(arm.consume(isMicrophoneTest: true))
        XCTAssertTrue(arm.isArmed)
        XCTAssertTrue(arm.consume(isMicrophoneTest: false))
        XCTAssertFalse(arm.isArmed)
        XCTAssertFalse(arm.consume(isMicrophoneTest: false))
    }

    func testStoreInitializationDoesNotCreateDiagnosticDirectory() {
        let root = temporaryRoot().appendingPathComponent("Diagnostics", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let store = WhisperDiagnosticStore(rootURL: root)

        XCTAssertTrue(store.captures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDiagnosticPackageWritesLinkedMetadataAndMatchingWAVDuration() async throws {
        let support = temporaryRoot()
        let root = support.appendingPathComponent("Diagnostics", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let store = WhisperDiagnosticStore(rootURL: root)
        let historyID = UUID()
        let samples = (0..<1_600).map { Float(sin(Double($0) / 10)) * 0.25 }
        let diagnostics = AudioDiagnostics(deviceID: "BuiltInMicrophoneDevice",
                                           deviceName: "MacBook Pro Mikrofonu",
                                           inputFormat: "16000 Hz · 1 kanal",
                                           callbackCount: 10, sampleCount: samples.count,
                                           peakLevel: 0.25, rmsLevel: 0.1,
                                           voicedDuration: 0.1, vadSegmentCount: 1,
                                           transcriptionChunkCount: 1, vadSpeechDuration: 0.1)
        let recording = AudioCapture(samples: samples, sampleRate: 16_000, duration: 0.1,
                                     diagnostics: diagnostics)
        let chunk = ChunkTranscriptionDiagnostic(
            index: 0, sourceStart: 0, sourceEnd: 0.1, speechDuration: 0.1,
            firstPassText: "Deneme.", firstPassConfidence: 0.8,
            firstPassTokenCount: 2, detectedLanguage: "tr", firstPassMilliseconds: 10,
            retryReason: nil, retryText: nil, retryConfidence: nil,
            retryTokenCount: nil, retryMilliseconds: nil,
            selectedText: "Deneme.", recovered: false
        )

        let id = try await store.save(
            recording: recording, historyEntryID: historyID, mode: .dictation,
            audioDiagnostics: diagnostics,
            vadRegions: [SpeechRegion(startSample: 0, endSample: 1_600)],
            chunkDiagnostics: [chunk], rawTranscript: "Deneme.",
            deterministicText: "Deneme.", finalText: "Deneme."
        )

        let saved = try XCTUnwrap(store.captures.first)
        XCTAssertEqual(saved.id, id)
        XCTAssertEqual(saved.historyEntryID, historyID)
        XCTAssertEqual(saved.sampleCount, 1_600)
        XCTAssertEqual(saved.vadRegions, [DiagnosticSpeechRegion(region: SpeechRegion(startSample: 0, endSample: 1_600))])
        XCTAssertEqual(saved.chunkDiagnostics, [chunk])
        let wav = try Data(contentsOf: store.audioURL(for: id))
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(littleEndianUInt32(wav, offset: 24), 16_000)
        XCTAssertEqual(littleEndianUInt32(wav, offset: 40), UInt32(samples.count * 2))
        XCTAssertEqual(Double(wav.count - 44) / 2 / 16_000, recording.duration, accuracy: 0.000_001)

        let metadataData = try Data(contentsOf: store.directoryURL(for: id).appendingPathComponent("metadata.json"))
        XCTAssertEqual(try JSONDecoder().decode(WhisperDiagnosticCapture.self, from: metadataData), saved)
    }

    func testHistoryDiagnosticLinkIsBackwardCompatibleAndRoundTrips() throws {
        let diagnosticID = UUID()
        let entry = HistoryEntry(duration: 2, mode: .dictation, rawTranscript: "Ham",
                                 finalText: "Son", deterministicText: "Son",
                                 localCorrectedText: nil, diagnosticCaptureID: diagnosticID)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.diagnosticCaptureID, diagnosticID)

        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","timestamp":0,"duration":1,"mode":"dictation","rawTranscript":"Ham","finalText":"Son"}"#
        let legacyEntry = try JSONDecoder().decode(HistoryEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(legacyEntry.diagnosticCaptureID)
    }

    func testDeleteAllTouchesOnlyDiagnosticRoot() async throws {
        let support = temporaryRoot()
        let root = support.appendingPathComponent("Diagnostics", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = support.appendingPathComponent("history.json")
        let model = support.appendingPathComponent("Models/model.bin")
        try Data("history".utf8).write(to: history)
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model".utf8).write(to: model)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("capture"), withIntermediateDirectories: true)

        let store = WhisperDiagnosticStore(rootURL: root)
        await store.deleteAll()

        XCTAssertTrue(FileManager.default.fileExists(atPath: history.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DikteDiagnosticTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        let bytes = [UInt8](data[offset..<(offset + 4)])
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }
}
