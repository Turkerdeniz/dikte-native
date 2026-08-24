import Foundation

struct CorrectionEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var heard: String
    var corrected: String
    var isEnabled: Bool
    let createdAt: Date
    var useCount: Int

    init(id: UUID = UUID(), heard: String, corrected: String, isEnabled: Bool = true,
         createdAt: Date = Date(), useCount: Int = 0) {
        self.id = id
        self.heard = heard
        self.corrected = corrected
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.useCount = useCount
    }
}

struct CorrectionCandidate: Identifiable, Equatable, Sendable {
    let id = UUID()
    let heard: String
    let corrected: String
}

enum CorrectionLearner {
    static func candidates(original: String, corrected: String) -> [CorrectionCandidate] {
        let lhs = words(original)
        let rhs = words(corrected)
        guard lhs != rhs, !lhs.isEmpty, !rhs.isEmpty else { return [] }
        var prefix = 0
        while prefix < min(lhs.count, rhs.count), equivalent(lhs[prefix], rhs[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < min(lhs.count - prefix, rhs.count - prefix),
              equivalent(lhs[lhs.count - suffix - 1], rhs[rhs.count - suffix - 1]) { suffix += 1 }
        let leftEnd = max(prefix, lhs.count - suffix)
        let rightEnd = max(prefix, rhs.count - suffix)
        let heard = lhs[prefix..<leftEnd].joined(separator: " ")
        let replacement = rhs[prefix..<rightEnd].joined(separator: " ")
        guard !heard.isEmpty, !replacement.isEmpty,
              heard.split(separator: " ").count <= 8,
              replacement.split(separator: " ").count <= 8 else { return [] }
        return [CorrectionCandidate(heard: heard, corrected: replacement)]
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .punctuationCharacters) ==
        rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .punctuationCharacters)
    }
}

@MainActor
final class CorrectionStore: ObservableObject {
    @Published private(set) var entries: [CorrectionEntry] = []
    private let fileURL: URL

    init(fileURL: URL = AppPaths.correctionsFile) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([CorrectionEntry].self, from: data) {
            entries = decoded
        }
    }

    var promptTerms: [String] {
        Array(Set(["Codex", "Dikte", "Whisper", "Option D"] +
                  entries.filter(\.isEnabled).map(\.corrected))).sorted()
    }

    var promptPairs: [String] {
        entries.filter(\.isEnabled).map { "\($0.heard) → \($0.corrected)" }
    }

    func confirm(_ candidates: [CorrectionCandidate]) {
        for candidate in candidates where !candidate.heard.isEmpty && !candidate.corrected.isEmpty {
            if let index = entries.firstIndex(where: {
                $0.heard.localizedCaseInsensitiveCompare(candidate.heard) == .orderedSame &&
                $0.corrected.localizedCaseInsensitiveCompare(candidate.corrected) == .orderedSame
            }) {
                entries[index].isEnabled = true
                entries[index].useCount += 1
            } else {
                entries.append(CorrectionEntry(heard: candidate.heard, corrected: candidate.corrected))
            }
        }
        persist()
    }

    func setEnabled(id: UUID, enabled: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isEnabled = enabled
        persist()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Correction dictionary write failed: \(error)")
        }
    }
}
