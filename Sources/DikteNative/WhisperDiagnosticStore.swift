import Foundation

struct OneShotDiagnosticCaptureArm: Equatable, Sendable {
    private(set) var isArmed = false

    mutating func toggle() { isArmed.toggle() }

    mutating func consume(isMicrophoneTest: Bool) -> Bool {
        guard !isMicrophoneTest, isArmed else { return false }
        isArmed = false
        return true
    }
}

struct DiagnosticSpeechRegion: Codable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    init(region: SpeechRegion, sampleRate: Double = 16_000) {
        start = Double(region.startSample) / sampleRate
        end = Double(region.endSample) / sampleRate
    }
}

struct WhisperDiagnosticCapture: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let historyEntryID: UUID
    let createdAt: Date
    let duration: TimeInterval
    let sampleRate: Int
    let sampleCount: Int
    let audioByteCount: Int
    let mode: HistoryMode
    let audioDiagnostics: AudioDiagnostics
    let vadRegions: [DiagnosticSpeechRegion]
    let chunkDiagnostics: [ChunkTranscriptionDiagnostic]
    let rawTranscript: String
    let deterministicText: String?
    let finalText: String
}

enum PCM16WAVEncoder {
    static func encode(samples: [Float], sampleRate: Int = 16_000) -> Data {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataByteCount = samples.count * bytesPerSample
        let byteRate = UInt32(sampleRate * Int(channelCount) * bytesPerSample)
        let blockAlign = channelCount * UInt16(bytesPerSample)

        var data = Data(capacity: 44 + dataByteCount)
        data.append(contentsOf: Data("RIFF".utf8))
        append(UInt32(36 + dataByteCount), to: &data)
        data.append(contentsOf: Data("WAVE".utf8))
        data.append(contentsOf: Data("fmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(channelCount, to: &data)
        append(UInt32(sampleRate), to: &data)
        append(byteRate, to: &data)
        append(blockAlign, to: &data)
        append(bitsPerSample, to: &data)
        data.append(contentsOf: Data("data".utf8))
        append(UInt32(dataByteCount), to: &data)

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let scaled = clamped == -1 ? Int16.min : Int16((clamped * Float(Int16.max)).rounded())
            append(scaled, to: &data)
        }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

@MainActor
final class WhisperDiagnosticStore: ObservableObject {
    @Published private(set) var captures: [WhisperDiagnosticCapture] = []
    let rootURL: URL

    init(rootURL: URL = AppPaths.whisperDiagnostics) {
        self.rootURL = rootURL
        captures = Self.loadCaptures(from: rootURL)
    }

    var totalAudioBytes: Int { captures.reduce(0) { $0 + $1.audioByteCount } }

    func save(recording: AudioCapture, historyEntryID: UUID, mode: HistoryMode,
              audioDiagnostics: AudioDiagnostics,
              vadRegions: [SpeechRegion], chunkDiagnostics: [ChunkTranscriptionDiagnostic],
              rawTranscript: String, deterministicText: String?, finalText: String) async throws -> UUID {
        let id = UUID()
        let samples = AudioResampler.to16kHz(recording)
        let audio = PCM16WAVEncoder.encode(samples: samples)
        let diagnosticRegions = vadRegions.map { DiagnosticSpeechRegion(region: $0) }
        let createdAt = Date()
        let metadata = WhisperDiagnosticCapture(
            id: id, historyEntryID: historyEntryID, createdAt: createdAt, duration: recording.duration,
            sampleRate: 16_000, sampleCount: samples.count, audioByteCount: audio.count,
            mode: mode, audioDiagnostics: audioDiagnostics,
            vadRegions: diagnosticRegions,
            chunkDiagnostics: chunkDiagnostics, rawTranscript: rawTranscript,
            deterministicText: deterministicText, finalText: finalText
        )
        let rootURL = rootURL
        try await Task.detached(priority: .utility) {
            try Self.write(metadata: metadata, audio: audio, rootURL: rootURL)
        }.value
        captures.insert(metadata, at: 0)
        return id
    }

    func delete(id: UUID) async {
        let directory = directoryURL(for: id)
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
        captures.removeAll { $0.id == id }
    }

    func deleteAll() async {
        let rootURL = rootURL
        await Task.detached(priority: .utility) {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: rootURL, includingPropertiesForKeys: nil
            ) else { return }
            for item in contents { try? FileManager.default.removeItem(at: item) }
        }.value
        captures.removeAll()
    }

    func directoryURL(for id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }
    func audioURL(for id: UUID) -> URL { directoryURL(for: id).appendingPathComponent("audio.wav") }

    private nonisolated static func write(metadata: WhisperDiagnosticCapture, audio: Data, rootURL: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let staging = rootURL.appendingPathComponent("\(metadata.id.uuidString).part", isDirectory: true)
        let destination = rootURL.appendingPathComponent(metadata.id.uuidString, isDirectory: true)
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try audio.write(to: staging.appendingPathComponent("audio.wav"), options: .atomic)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metadata).write(to: staging.appendingPathComponent("metadata.json"), options: .atomic)
            try manager.moveItem(at: staging, to: destination)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    private nonisolated static func loadCaptures(from rootURL: URL) -> [WhisperDiagnosticCapture] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = JSONDecoder()
        return directories.compactMap { directory in
            guard directory.pathExtension != "part",
                  let data = try? Data(contentsOf: directory.appendingPathComponent("metadata.json")) else { return nil }
            return try? decoder.decode(WhisperDiagnosticCapture.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }
}
