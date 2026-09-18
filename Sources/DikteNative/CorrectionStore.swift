import AppKit
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
    /// True when `heard` is an ordinary word of the recognition language rather
    /// than a garbled non-word. See `CorrectionRisk`.
    var replacesARealWord = false
}

/// A taught correction is a context-free find-and-replace, so it cannot tell the
/// two senses of a word apart. Teaching "boyut" → "build" because the recogniser
/// misheard the English word is reasonable and useful, but it also rewrites the
/// ordinary Turkish "boyut" wherever it is genuinely meant, and nothing in the
/// pipeline can distinguish them.
///
/// What is checkable is whether the misheard side is a real word at all. The
/// corrections that are always safe replace non-words the language never
/// produces — "syskaydı", "buyıt", "vadan". The ones that can misfire replace
/// something the user might really say. The system dictionary answers that
/// offline, so those corrections are surfaced and require a deliberate choice
/// instead of being switched on silently.
enum CorrectionRisk {
    /// How unsure the recogniser has to have been before a taught correction is
    /// allowed to rewrite an ordinary word.
    ///
    /// This shared `TranscriptWord.uncertainThreshold` until measurement showed
    /// the two jobs pull opposite ways. The highlight wants precision: a mark
    /// that is usually wrong is noise, so it belongs at the bottom of the
    /// distribution. This gate wants reach: a genuine mishearing the user has
    /// already taught a correction for sits anywhere under ~0.60; the ones
    /// measured here landed between 0.44 and 0.46. Refusing to apply it there
    /// brings back the oldest complaint about this feature, that a taught
    /// correction never seems to do anything. Letting one constant follow the
    /// highlight down would have done exactly that silently.
    static let unsureEnoughToRewriteThreshold: Float = 0.60

    static func replacesARealWord(_ heard: String, language: RecognitionLanguage) -> Bool {
        guard let code = language.spellCheckerLanguage else { return false }
        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // A multi-word phrase is specific enough that an accidental match is not
        // the concern; only a single ordinary word is.
        guard !trimmed.contains(" ") else { return false }
        let range = NSSpellChecker.shared.checkSpelling(
            of: trimmed, startingAt: 0, language: code, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }
}

enum CorrectionLearner {
    /// A taught pair only ever helps if the same wording turns up again, and a
    /// long one never does: the recogniser does not repeat a whole misheard
    /// sentence verbatim. Pairs longer than this are dropped rather than stored
    /// as entries that can never match.
    static let maximumCandidateWords = 3
    /// The alignment below is quadratic, so a very long transcript is left alone
    /// rather than stalling the settings sheet.
    static let maximumComparableWords = 600

    /// Extracts one pair per changed region.
    ///
    /// This used to trim the common prefix and the common suffix and return the
    /// single span between them, which meant that correcting two separate words
    /// in one sentence also swallowed every correct word in between — the stored
    /// pair became a sentence-length fragment that could never match again.
    /// Aligning the two word sequences properly yields the individual edits, so
    /// "X kodu ... buyıt" against "Xcode'u ... build" now teaches "X kodu" →
    /// "Xcode'u" and "buyıt" → "build" as separate, reusable corrections.
    static func candidates(original: String, corrected: String) -> [CorrectionCandidate] {
        let lhs = words(original)
        let rhs = words(corrected)
        guard lhs != rhs, !lhs.isEmpty, !rhs.isEmpty,
              lhs.count <= maximumComparableWords, rhs.count <= maximumComparableWords else { return [] }
        return differingRuns(lhs, rhs).compactMap { run in
            let heard = lhs[run.left].joined(separator: " ")
            let replacement = rhs[run.right].joined(separator: " ")
            // A pure insertion or deletion has nothing safe to find or to put in
            // its place, so it is not offered as a correction.
            guard !heard.isEmpty, !replacement.isEmpty,
                  run.left.count <= maximumCandidateWords,
                  run.right.count <= maximumCandidateWords else { return nil }
            return CorrectionCandidate(heard: heard, corrected: replacement)
        }
    }

    private static func differingRuns(_ lhs: [String], _ rhs: [String]) -> [(left: Range<Int>, right: Range<Int>)] {
        let left = lhs.map(normalized)
        let right = rhs.map(normalized)
        var table = [[Int]](repeating: [Int](repeating: 0, count: right.count + 1), count: left.count + 1)
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                table[i][j] = left[i] == right[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var runs: [(left: Range<Int>, right: Range<Int>)] = []
        var i = 0, j = 0, startI = 0, startJ = 0
        var inRun = false
        while i < left.count || j < right.count {
            if i < left.count, j < right.count, left[i] == right[j] {
                if inRun {
                    runs.append((left: startI..<i, right: startJ..<j))
                    inRun = false
                }
                i += 1
                j += 1
            } else {
                if !inRun {
                    startI = i
                    startJ = j
                    inRun = true
                }
                if j < right.count, i == left.count || table[i][j + 1] >= table[i + 1][j] { j += 1 } else { i += 1 }
            }
        }
        if inRun { runs.append((left: startI..<left.count, right: startJ..<right.count)) }
        return runs
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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

    func confirm(_ candidates: [CorrectionCandidate]) {
        for candidate in candidates where !candidate.heard.isEmpty && !candidate.corrected.isEmpty {
            if let index = entries.firstIndex(where: {
                $0.heard.localizedCaseInsensitiveCompare(candidate.heard) == .orderedSame &&
                $0.corrected.localizedCaseInsensitiveCompare(candidate.corrected) == .orderedSame
            }) {
                entries[index].isEnabled = true
            } else {
                entries.append(CorrectionEntry(heard: candidate.heard, corrected: candidate.corrected))
            }
        }
        persist()
    }

    /// Increments `useCount` for corrections that just fired for real in
    /// `TextCleaner.applyCorrections`. This is the only place `useCount` moves,
    /// so it means exactly "this correction changed a transcript N times" — not
    /// "I taught this N times", which re-teaching the same pair via `confirm`
    /// does not count as.
    func recordApplied(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        for index in entries.indices where idSet.contains(entries[index].id) {
            entries[index].useCount += 1
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
