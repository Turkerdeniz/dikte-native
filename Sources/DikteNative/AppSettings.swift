import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let language = "language"
        static let hotKey = "hotKey"
        static let automaticPaste = "automaticPaste"
        static let maximumRecording = "maximumRecording"
        static let overlayPosition = "overlayPosition"
        static let codexThreshold = "codexThreshold"
        static let codexThreadID = "codexThreadID"
        static let codingCodexThreadID = "codingCodexThreadID"
        static let migrationVersion = "migrationVersion"
    }
    private let defaults: UserDefaults

    @Published var language: RecognitionLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    @Published var hotKey: HotKeyConfiguration { didSet { save(hotKey, key: Key.hotKey) } }
    @Published var automaticPaste: Bool { didSet { defaults.set(automaticPaste, forKey: Key.automaticPaste) } }
    @Published var maximumRecording: Double { didSet { defaults.set(maximumRecording, forKey: Key.maximumRecording) } }
    @Published var overlayPosition: OverlayPosition { didSet { defaults.set(overlayPosition.rawValue, forKey: Key.overlayPosition) } }
    @Published var codexThreshold: Double { didSet { defaults.set(codexThreshold, forKey: Key.codexThreshold) } }
    @Published var codexThreadID: String? { didSet { defaults.set(codexThreadID, forKey: Key.codexThreadID) } }
    @Published var codingCodexThreadID: String? { didSet { defaults.set(codingCodexThreadID, forKey: Key.codingCodexThreadID) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.removeObject(forKey: "microphoneID")
        let storedLanguage = RecognitionLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .turkish
        if let data = defaults.data(forKey: Key.hotKey), let value = try? JSONDecoder().decode(HotKeyConfiguration.self, from: data) {
            hotKey = value
        } else { hotKey = .optionD }
        automaticPaste = defaults.object(forKey: Key.automaticPaste) as? Bool ?? true
        maximumRecording = defaults.object(forKey: Key.maximumRecording) as? Double ?? 600
        let storedOverlay = OverlayPosition(rawValue: defaults.string(forKey: Key.overlayPosition) ?? "") ?? .bottomLeft
        let storedThreshold = defaults.object(forKey: Key.codexThreshold) as? Double ?? 30
        let migrationVersion = defaults.integer(forKey: Key.migrationVersion)
        language = migrationVersion < 5 ? .turkish : storedLanguage
        overlayPosition = migrationVersion < 4 ? .bottomLeft : storedOverlay
        codexThreshold = migrationVersion < 1 && abs(storedThreshold - 0.1) < 0.0001 ? 30 : storedThreshold
        if migrationVersion < 6 {
            codexThreadID = nil
            defaults.removeObject(forKey: Key.codexThreadID)
        } else {
            codexThreadID = defaults.string(forKey: Key.codexThreadID)
        }
        if migrationVersion < 7 {
            codingCodexThreadID = nil
            defaults.removeObject(forKey: Key.codingCodexThreadID)
        } else {
            codingCodexThreadID = defaults.string(forKey: Key.codingCodexThreadID)
        }
        if migrationVersion < 1 {
            defaults.set(codexThreshold, forKey: Key.codexThreshold)
        }
        if migrationVersion < 8, maximumRecording < 600 {
            maximumRecording = 600
            defaults.set(maximumRecording, forKey: Key.maximumRecording)
        }
        defaults.removeObject(forKey: "smartCleanupEnabled")
        if migrationVersion < 5 { defaults.set(language.rawValue, forKey: Key.language) }
        if migrationVersion < 4 { defaults.set(overlayPosition.rawValue, forKey: Key.overlayPosition) }
        defaults.set(8, forKey: Key.migrationVersion)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
