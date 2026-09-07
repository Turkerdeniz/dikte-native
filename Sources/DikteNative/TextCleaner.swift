import Foundation

enum TextCleaner {
    private static let mojibake: [String: String] = [
        "≈ü": "ş", "√∂": "ö", "ƒ±": "ı", "ƒü": "ğ", "√ß": "ç",
        "Ã§": "ç", "Ã¶": "ö", "Ã¼": "ü", "Ä±": "ı", "Ä°": "İ", "ÅŸ": "ş", "ÄŸ": "ğ"
    ]

    static func clean(_ input: String) -> String {
        var value = input
        for (broken, fixed) in mojibake { value = value.replacingOccurrences(of: broken, with: fixed) }
        value = value.replacingOccurrences(
            of: #"(?i)(^|[\s,])(?:ı+|uh+|um+|hmm+|eee+|ıı+)(?=[\s,.!?]|$)"#,
            with: "$1", options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)\b([\p{L}\p{N}']+)(?:\s+\1\b)+"#,
            with: "$1", options: .regularExpression
        )
        value = value.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"([,.;:!?])(?=[\p{L}\p{N}])"#, with: "$1 ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Deterministically applies confirmed "heard → corrected" corrections on top
    /// of the cleaned transcript. This is separate from, and in addition to, the
    /// soft vocabulary hint the same corrections give Whisper via `initial_prompt`
    /// (see `CorrectionStore.promptTerms`): that hint only nudges recognition
    /// probabilistically, so a taught correction with no deterministic follow-up
    /// step had no guaranteed effect on the final text. Matching is whole-word,
    /// case-insensitive, and does not fold diacritics — a correction should not
    /// fire on a merely similar-looking word.
    static func applyCorrections(_ text: String, entries: [CorrectionEntry]) -> (text: String, appliedIDs: [UUID]) {
        var result = text
        var appliedIDs: [UUID] = []
        for entry in entries where entry.isEnabled {
            let heard = entry.heard.trimmingCharacters(in: .whitespacesAndNewlines)
            let corrected = entry.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty, !corrected.isEmpty else { continue }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: heard) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let fullRange = NSRange(result.startIndex..., in: result)
            guard regex.firstMatch(in: result, range: fullRange) != nil else { continue }
            let replacement = NSRegularExpression.escapedTemplate(for: corrected)
            result = regex.stringByReplacingMatches(in: result, range: fullRange, withTemplate: replacement)
            appliedIDs.append(entry.id)
        }
        return (result, appliedIDs)
    }
}

enum TranscriptionPolicy {
    private static let commonSilenceHallucinations = [
        "lütfen kanalıma abone olmayı ve videoyu beğenmeyi unutmayın",
        "kanalıma abone olmayı ve videoyu beğenmeyi unutmayın",
        "videoyu izlediğiniz için teşekkür ederim",
        "izlediğiniz için teşekkür ederim",
        "videoyu izlediğiniz için teşekkürler",
        "izlediğiniz için teşekkürler",
        "bir sonraki videoda görüşmek üzere",
        "altyazı m.k.",
        "abone olmayı unutmayın"
    ].sorted { $0.count > $1.count }

    /// Whisper reports a probability per decoded token, and the app already
    /// aggregates two summaries of them: the mean, and the share that fall below
    /// `ChunkAcceptancePolicy.weakTokenThreshold`. Until now both were only
    /// recorded for display. A transcript invented over noise or silence has a
    /// characteristic signature in that pair — a low mean *and* most tokens weak —
    /// whereas genuine speech recorded badly usually still contains confident
    /// anchors that keep one of the two in normal territory. Both conditions are
    /// therefore required, and very short outputs are exempt because a handful of
    /// tokens makes the mean too noisy to judge.
    ///
    /// This deliberately does not reject the text. A false positive here would
    /// throw away something the user actually said, so the caller downgrades the
    /// result — the transcript still reaches the clipboard and History — rather
    /// than discarding it.
    static let hallucinationMeanProbability: Float = 0.35
    static let hallucinationWeakTokenRatio: Float = 0.60
    static let minimumTokensForConfidenceJudgement = 4

    static func isConfidenceTooLow(meanTokenProbability: Float, lowConfidenceTokenRatio: Float,
                                   tokenCount: Int) -> Bool {
        guard tokenCount >= minimumTokensForConfidenceJudgement else { return false }
        return meanTokenProbability < hallucinationMeanProbability
            && lowConfidenceTokenRatio > hallucinationWeakTokenRatio
    }

    static func accepts(_ text: String, voicedDuration: TimeInterval) -> Bool {
        guard voicedDuration >= 0.20 else { return false }
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }

        var remainder = normalized
        for hallucination in commonSilenceHallucinations {
            remainder = remainder.replacingOccurrences(of: normalize(hallucination), with: " ")
        }
        remainder = normalize(remainder)
        if remainder.isEmpty { return false }
        return !normalized.isEmpty
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
