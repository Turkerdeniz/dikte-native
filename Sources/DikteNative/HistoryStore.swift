import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    init(fileURL: URL = AppPaths.historyFile) {
        self.fileURL = fileURL
        load()
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 100 { entries.removeLast(entries.count - 100) }
        persist()
    }

    func delete(id: UUID) { entries.removeAll { $0.id == id }; persist() }
    func deleteAll() { entries.removeAll(); persist() }
    func correct(id: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let old = entries[index]
        entries[index] = HistoryEntry(id: old.id, timestamp: old.timestamp, duration: old.duration,
                                      mode: old.mode, captureMode: old.captureMode,
                                      rawTranscript: old.rawTranscript, finalText: text,
                                      deterministicText: old.deterministicText,
                                      localCorrectedText: old.localCorrectedText,
                                      accurateTranscript: old.accurateTranscript,
                                      accuratePassReason: old.accuratePassReason,
                                      primaryConfidence: old.primaryConfidence,
                                      accurateConfidence: old.accurateConfidence,
                                      lowConfidenceTokenRatio: old.lowConfidenceTokenRatio,
                                      wordsPerSecond: old.wordsPerSecond,
                                      charactersPerSecond: old.charactersPerSecond,
                                      accurateModelSelected: old.accurateModelSelected,
                                      modelSelectionReason: old.modelSelectionReason,
                                      codexResponse: old.codexResponse, codexError: old.codexError,
                                      audioDiagnostics: old.audioDiagnostics,
                                      chunkDiagnostics: old.chunkDiagnostics,
                                      performanceDiagnostics: old.performanceDiagnostics,
                                      diagnosticCaptureID: old.diagnosticCaptureID)
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = Array(decoded.prefix(100))
    }

    private func persist() {
        guard let data = try? encoder.encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch { NSLog("History write failed: \(error)") }
    }
}

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Dikte Native", isDirectory: true)
    }()
    static let models = support.appendingPathComponent("Models", isDirectory: true)
    static let model = models.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
    static let modelPart = models.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin.part")
    static let modelVerificationReceipt = models.appendingPathComponent("model-verification.json")
    static let historyFile = support.appendingPathComponent("history.json")
    static let codexRuntime = support.appendingPathComponent("CodexRuntime", isDirectory: true)
    static let correctionsFile = support.appendingPathComponent("corrections.json")
    static let crashBreadcrumbFile = support.appendingPathComponent("active-session.json")
    static let whisperDiagnostics = support.appendingPathComponent("Diagnostics", isDirectory: true)
}
