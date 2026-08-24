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
