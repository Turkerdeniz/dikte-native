import Foundation

enum ProcessingStage: String, Codable, Sendable {
    case preparingAudio, segmentingSpeech, preparingModel, transcribing, retryingTranscription, cleaning, askingCodex, copying

    var title: String {
        switch self {
        case .preparingAudio: "Ses hazırlanıyor…"
        case .segmentingSpeech: "Konuşma bölümleri ayrılıyor…"
        case .preparingModel: "Model hazırlanıyor…"
        case .transcribing: "Yazıya çevriliyor…"
        case .retryingTranscription: "Eksik konuşma bölümü yeniden çözülüyor…"
        case .cleaning: "Metin temizleniyor…"
        case .askingCodex: "Codex’e gönderiliyor…"
        case .copying: "Kopyalanıyor…"
        }
    }
}

enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case general
    case coding

    var title: String {
        switch self {
        case .general: "Ham"
        case .coding: "Kısa ve Net"
        }
    }
}

enum AppPhase: Equatable, Sendable {
    case idle
    case arming(startedAt: Date, attempt: Int)
    case recording(startedAt: Date)
    case processing(ProcessingStage)
}

extension AppPhase {
    var diagnosticName: String {
        switch self {
        case .idle: "idle"
        case .arming(_, let attempt): "arming-\(attempt)"
        case .recording: "recording"
        case .processing(let stage): "processing-\(stage.rawValue)"
        }
    }
}

enum CaptureHotKeyAction: Equatable, Sendable {
    case start(CaptureMode)
    case stop
    case ignore
}

enum CaptureHotKeyPolicy {
    static func action(for phase: AppPhase, activeMode: CaptureMode,
                       requestedMode: CaptureMode, isStarting: Bool = false) -> CaptureHotKeyAction {
        guard !isStarting || phase != .idle else { return .ignore }
        switch phase {
        case .idle: return .start(requestedMode)
        case .arming, .recording: return activeMode == requestedMode ? .stop : .ignore
        case .processing: return .ignore
        }
    }
}

enum RecognitionLanguage: String, CaseIterable, Codable, Identifiable {
    case automatic, turkish, english
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Otomatik"
        case .turkish: "Türkçe"
        case .english: "English"
        }
    }
    var whisperCode: String? {
        switch self {
        case .automatic: nil
        case .turkish: "tr"
        case .english: "en"
        }
    }
}

enum OverlayPosition: String, CaseIterable, Codable, Identifiable {
    case bottomLeft = "bottom-left"
    case top
    var id: String { rawValue }
    var title: String { self == .top ? "Üst orta · Geniş" : "Sol alt · Kompakt" }
    var isCompact: Bool { self == .bottomLeft }
}

struct HotKeyConfiguration: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var displayName: String

    static let optionD = HotKeyConfiguration(keyCode: 2, modifiers: 1 << 11, displayName: "⌥D")
    static let optionE = HotKeyConfiguration(keyCode: 14, modifiers: 1 << 11, displayName: "⌥E")

    func matchesShortcut(_ other: HotKeyConfiguration) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

enum HistoryMode: String, Codable, Sendable {
    case dictation, autoAsk = "auto-ask", incomplete, recordingError = "recording-error"
}

struct ChunkTranscriptionDiagnostic: Codable, Equatable, Sendable, Identifiable {
    var id: Int { index }
    let index: Int
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    let speechDuration: TimeInterval
    let firstPassText: String
    let firstPassConfidence: Float
    let firstPassTokenCount: Int
    let detectedLanguage: String?
    let firstPassMilliseconds: Double
    let retryReason: String?
    let retryText: String?
    let retryConfidence: Float?
    let retryTokenCount: Int?
    let retryMilliseconds: Double?
    let selectedText: String
    let recovered: Bool
}

struct StageDuration: Codable, Equatable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let milliseconds: Double
}

struct PerformanceDiagnostics: Codable, Equatable, Sendable {
    let stages: [StageDuration]
    let totalMilliseconds: Double
    let userCPUMilliseconds: Double
    let systemCPUMilliseconds: Double
    let residentBytesStart: UInt64
    let residentBytesEnd: UInt64
    let physicalFootprintBytesStart: UInt64
    let physicalFootprintBytesEnd: UInt64
    let diskReadBytes: UInt64
    let diskWrittenBytes: UInt64
    let threadCountStart: Int
    let threadCountEnd: Int
    let thermalState: String
    let audioLevelReceivedCount: Int?
    let audioLevelRenderedCount: Int?
    let audioLevelCoalescedCount: Int?
    let maximumAudioLevelLagMilliseconds: Double?
    let overlayQueryCount: Int?
    let overlaySkippedQueryCount: Int?
    let maximumOverlayQueryMilliseconds: Double?
    let modelLoadMilliseconds: Double?
    let modelUnloadMilliseconds: Double?
}

struct AudioDiagnostics: Codable, Equatable, Sendable {
    var deviceID: String = ""
    var deviceName: String = ""
    var inputFormat: String = ""
    var callbackCount: Int = 0
    var sampleCount: Int = 0
    var peakLevel: Float = 0
    var rmsLevel: Float = 0
    var voicedDuration: TimeInterval = 0
    var restartCount: Int = 0
    var conversionErrors: Int = 0
    var vadSegmentCount: Int = 0
    var transcriptionChunkCount: Int = 0
    var vadSpeechDuration: TimeInterval = 0
    var vadFallbackReason: String?

    init(deviceID: String = "", deviceName: String = "", inputFormat: String = "",
         callbackCount: Int = 0, sampleCount: Int = 0, peakLevel: Float = 0,
         rmsLevel: Float = 0, voicedDuration: TimeInterval = 0, restartCount: Int = 0,
         conversionErrors: Int = 0, vadSegmentCount: Int = 0,
         transcriptionChunkCount: Int = 0, vadSpeechDuration: TimeInterval = 0,
         vadFallbackReason: String? = nil) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.inputFormat = inputFormat
        self.callbackCount = callbackCount; self.sampleCount = sampleCount
        self.peakLevel = peakLevel; self.rmsLevel = rmsLevel; self.voicedDuration = voicedDuration
        self.restartCount = restartCount; self.conversionErrors = conversionErrors
        self.vadSegmentCount = vadSegmentCount; self.transcriptionChunkCount = transcriptionChunkCount
        self.vadSpeechDuration = vadSpeechDuration; self.vadFallbackReason = vadFallbackReason
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID, deviceName, inputFormat, callbackCount, sampleCount, peakLevel, rmsLevel
        case voicedDuration, restartCount, conversionErrors, vadSegmentCount, transcriptionChunkCount
        case vadSpeechDuration, vadFallbackReason
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try box.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        deviceName = try box.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        inputFormat = try box.decodeIfPresent(String.self, forKey: .inputFormat) ?? ""
        callbackCount = try box.decodeIfPresent(Int.self, forKey: .callbackCount) ?? 0
        sampleCount = try box.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
        peakLevel = try box.decodeIfPresent(Float.self, forKey: .peakLevel) ?? 0
        rmsLevel = try box.decodeIfPresent(Float.self, forKey: .rmsLevel) ?? 0
        voicedDuration = try box.decodeIfPresent(TimeInterval.self, forKey: .voicedDuration) ?? 0
        restartCount = try box.decodeIfPresent(Int.self, forKey: .restartCount) ?? 0
        conversionErrors = try box.decodeIfPresent(Int.self, forKey: .conversionErrors) ?? 0
        vadSegmentCount = try box.decodeIfPresent(Int.self, forKey: .vadSegmentCount) ?? 0
        transcriptionChunkCount = try box.decodeIfPresent(Int.self, forKey: .transcriptionChunkCount) ?? 0
        vadSpeechDuration = try box.decodeIfPresent(TimeInterval.self, forKey: .vadSpeechDuration) ?? 0
        vadFallbackReason = try box.decodeIfPresent(String.self, forKey: .vadFallbackReason)
    }

    var summary: String {
        var value = "\(deviceName) · \(inputFormat) · \(callbackCount) paket · \(sampleCount) örnek · " +
            String(format: "RMS %.4f · tepe %.4f · konuşma %.1f sn · yeniden deneme %d · dönüşüm hatası %d",
                   rmsLevel, peakLevel, voicedDuration, restartCount, conversionErrors)
        if vadSegmentCount > 0 || transcriptionChunkCount > 0 {
            value += String(format: " · VAD %d bölüm / %d parça / %.1f sn",
                            vadSegmentCount, transcriptionChunkCount, vadSpeechDuration)
        }
        if let vadFallbackReason, !vadFallbackReason.isEmpty { value += " · VAD fallback: \(vadFallbackReason)" }
        return value
    }
}

struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let duration: TimeInterval
    let mode: HistoryMode
    let captureMode: CaptureMode?
    let rawTranscript: String
    let finalText: String
    let deterministicText: String?
    let localCorrectedText: String?
    let accurateTranscript: String?
    let accuratePassReason: String?
    let primaryConfidence: Float?
    let accurateConfidence: Float?
    let lowConfidenceTokenRatio: Float?
    let wordsPerSecond: Double?
    let charactersPerSecond: Double?
    let accurateModelSelected: Bool?
    let modelSelectionReason: String?
    let codexResponse: String?
    let codexError: String?
    let audioDiagnostics: AudioDiagnostics?
    let chunkDiagnostics: [ChunkTranscriptionDiagnostic]?
    let performanceDiagnostics: PerformanceDiagnostics?
    let diagnosticCaptureID: UUID?

    init(id: UUID = UUID(), timestamp: Date = Date(), duration: TimeInterval, mode: HistoryMode,
         captureMode: CaptureMode? = nil,
         rawTranscript: String, finalText: String, codexResponse: String? = nil, codexError: String? = nil) {
        self.init(id: id, timestamp: timestamp, duration: duration, mode: mode,
                  captureMode: captureMode,
                  rawTranscript: rawTranscript, finalText: finalText, deterministicText: nil,
                  localCorrectedText: nil, accurateTranscript: nil, accuratePassReason: nil,
                  primaryConfidence: nil, accurateConfidence: nil,
                  lowConfidenceTokenRatio: nil, wordsPerSecond: nil, charactersPerSecond: nil,
                  accurateModelSelected: nil, modelSelectionReason: nil,
                  codexResponse: codexResponse, codexError: codexError,
                  audioDiagnostics: nil, chunkDiagnostics: nil, performanceDiagnostics: nil,
                  diagnosticCaptureID: nil)
    }

    init(id: UUID = UUID(), timestamp: Date = Date(), duration: TimeInterval, mode: HistoryMode,
         captureMode: CaptureMode? = nil,
         rawTranscript: String, finalText: String, deterministicText: String?, localCorrectedText: String?,
         accurateTranscript: String? = nil, accuratePassReason: String? = nil,
         primaryConfidence: Float? = nil, accurateConfidence: Float? = nil,
         lowConfidenceTokenRatio: Float? = nil, wordsPerSecond: Double? = nil,
         charactersPerSecond: Double? = nil, accurateModelSelected: Bool? = nil,
         modelSelectionReason: String? = nil,
         codexResponse: String? = nil, codexError: String? = nil, audioDiagnostics: AudioDiagnostics? = nil,
         chunkDiagnostics: [ChunkTranscriptionDiagnostic]? = nil,
         performanceDiagnostics: PerformanceDiagnostics? = nil,
         diagnosticCaptureID: UUID? = nil) {
        self.id = id; self.timestamp = timestamp; self.duration = duration; self.mode = mode
        self.captureMode = captureMode
        self.rawTranscript = rawTranscript; self.finalText = finalText
        self.deterministicText = deterministicText; self.localCorrectedText = localCorrectedText
        self.accurateTranscript = accurateTranscript; self.accuratePassReason = accuratePassReason
        self.primaryConfidence = primaryConfidence; self.accurateConfidence = accurateConfidence
        self.lowConfidenceTokenRatio = lowConfidenceTokenRatio
        self.wordsPerSecond = wordsPerSecond; self.charactersPerSecond = charactersPerSecond
        self.accurateModelSelected = accurateModelSelected; self.modelSelectionReason = modelSelectionReason
        self.codexResponse = codexResponse; self.codexError = codexError
        self.audioDiagnostics = audioDiagnostics
        self.chunkDiagnostics = chunkDiagnostics; self.performanceDiagnostics = performanceDiagnostics
        self.diagnosticCaptureID = diagnosticCaptureID
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, duration, mode, captureMode, rawTranscript, finalText, deterministicText, localCorrectedText
        case accurateTranscript, accuratePassReason, primaryConfidence, accurateConfidence
        case lowConfidenceTokenRatio, wordsPerSecond, charactersPerSecond
        case accurateModelSelected, modelSelectionReason
        case codexResponse, codexError, audioDiagnostics, chunkDiagnostics, performanceDiagnostics
        case diagnosticCaptureID
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id)
        timestamp = try box.decode(Date.self, forKey: .timestamp)
        duration = try box.decode(TimeInterval.self, forKey: .duration)
        mode = try box.decode(HistoryMode.self, forKey: .mode)
        captureMode = try box.decodeIfPresent(CaptureMode.self, forKey: .captureMode)
        rawTranscript = try box.decode(String.self, forKey: .rawTranscript)
        finalText = try box.decode(String.self, forKey: .finalText)
        deterministicText = try box.decodeIfPresent(String.self, forKey: .deterministicText)
        localCorrectedText = try box.decodeIfPresent(String.self, forKey: .localCorrectedText)
        accurateTranscript = try box.decodeIfPresent(String.self, forKey: .accurateTranscript)
        accuratePassReason = try box.decodeIfPresent(String.self, forKey: .accuratePassReason)
        primaryConfidence = try box.decodeIfPresent(Float.self, forKey: .primaryConfidence)
        accurateConfidence = try box.decodeIfPresent(Float.self, forKey: .accurateConfidence)
        lowConfidenceTokenRatio = try box.decodeIfPresent(Float.self, forKey: .lowConfidenceTokenRatio)
        wordsPerSecond = try box.decodeIfPresent(Double.self, forKey: .wordsPerSecond)
        charactersPerSecond = try box.decodeIfPresent(Double.self, forKey: .charactersPerSecond)
        accurateModelSelected = try box.decodeIfPresent(Bool.self, forKey: .accurateModelSelected)
        modelSelectionReason = try box.decodeIfPresent(String.self, forKey: .modelSelectionReason)
        codexResponse = try box.decodeIfPresent(String.self, forKey: .codexResponse)
        codexError = try box.decodeIfPresent(String.self, forKey: .codexError)
        audioDiagnostics = try box.decodeIfPresent(AudioDiagnostics.self, forKey: .audioDiagnostics)
        chunkDiagnostics = try box.decodeIfPresent([ChunkTranscriptionDiagnostic].self, forKey: .chunkDiagnostics)
        performanceDiagnostics = try box.decodeIfPresent(PerformanceDiagnostics.self, forKey: .performanceDiagnostics)
        diagnosticCaptureID = try box.decodeIfPresent(UUID.self, forKey: .diagnosticCaptureID)
    }
}

enum DikteError: LocalizedError {
    case microphonePermission, noAudio, noSpeech, modelMissing, modelInvalid, transcriptionFailed, hotKeyConflict, codexUnavailable
    case message(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermission: "Mikrofon izni verilmedi."
        case .noAudio: "Kaydedilmiş ses bulunamadı."
        case .noSpeech: "Ses yok."
        case .modelMissing: "Whisper modeli henüz indirilmedi."
        case .modelInvalid: "İndirilen model doğrulanamadı."
        case .transcriptionFailed: "Ses yazıya çevrilemedi."
        case .hotKeyConflict: "Bu kısayol başka bir uygulama tarafından kullanılıyor."
        case .codexUnavailable: "Codex bu Mac’te bulunamadı."
        case .message(let text): text
        }
    }
}
