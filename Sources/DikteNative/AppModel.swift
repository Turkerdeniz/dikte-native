import AppKit
import AVFoundation
import Foundation
import OSLog
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: AppPhase = .idle {
        didSet {
            breadcrumbStore.update(stage: phase.diagnosticName,
                                   modelLoaded: modelStore.isLoaded,
                                   memoryPressureLevel: memoryPressureLevel)
        }
    }
    @Published var alertMessage: String?
    @Published private(set) var lastResult: String?
    @Published private(set) var loginAtStartup = false
    @Published private(set) var microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var audioLevels = [Float](repeating: 0, count: 34)
    @Published private(set) var lastAudioDiagnostics: AudioDiagnostics?
    @Published private(set) var isMicrophoneTest = false

    let settings = AppSettings()
    let history = HistoryStore()
    let modelStore = ModelStore()
    let vadModelStore = VADModelStore()
    let corrections = CorrectionStore()
    let recorder = AudioRecorder()
    let pasteService = PasteService()
    private let hotKey = HotKeyManager()
    private let whisper = WhisperEngine()
    private let speechSegmenter = SpeechSegmenter()
    private let codex = CodexClient()
    private var processingTask: Task<Void, Never>?
    private var modelPreloadTask: Task<Void, Never>?
    private var armingTimeoutTask: Task<Void, Never>?
    private var maximumRecordingTask: Task<Void, Never>?
    private var performanceTracker: PerformanceTracker?
    private var memoryPressureMonitor: MemoryPressureMonitor?
    private var memoryPressureTask: Task<Void, Never>?
    private var modelReleaseTask: Task<Void, Never>?
    private var memoryPressureLevel: MemoryPressureLevel = .normal
    private var pendingMemoryRelease = false
    private let breadcrumbStore = CrashBreadcrumbStore()
    private let overlay = OverlayController()
    private static let lifecycleLog = Logger(subsystem: "com.turkerdenizer.dikte.native", category: "Lifecycle")

    init() {
        recoverUnexpectedCrash()
        removeLegacyAccurateModel()
        loginAtStartup = SMAppService.mainApp.status == .enabled
        do { try installHotKey(settings.hotKey) } catch { alertMessage = error.localizedDescription }
        Task { try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        configureMemoryPressureHandling()
    }

    var isRecording: Bool { if case .recording = phase { true } else { false } }
    var isArming: Bool { if case .arming = phase { true } else { false } }
    var isCapturing: Bool { isArming || isRecording }
    var isProcessing: Bool { if case .processing = phase { true } else { false } }

    func toggleRecording() {
        switch phase {
        case .idle: Task { await startRecording() }
        case .arming, .recording: stopRecording()
        case .processing: break
        }
    }

    func startRecording() async {
        isMicrophoneTest = false
        await startCapture(maximumDuration: settings.maximumRecording)
    }

    func startMicrophoneTest() {
        guard phase == .idle else {
            if isMicrophoneTest && isCapturing { stopRecording() }
            return
        }
        isMicrophoneTest = true
        Task { await startCapture(maximumDuration: 5) }
    }

    private func startCapture(maximumDuration: TimeInterval) async {
        guard phase == .idle else { return }
        let microphoneGranted = await recorder.requestPermission()
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
        guard microphoneGranted else {
            isMicrophoneTest = false
            alertMessage = "Mikrofon izni verilmedi. General bölümündeki Mikrofon İzni düğmesinden Sistem Ayarları’nı açabilirsin."
            return
        }
        do {
            let startedAt = Date()
            breadcrumbStore.begin(stage: "arming-1", modelLoaded: modelStore.isLoaded,
                                  memoryPressureLevel: memoryPressureLevel)
            performanceTracker = PerformanceTracker()
            performanceTracker?.begin("Kayıt")
            audioLevels = [Float](repeating: 0, count: 34)
            phase = .arming(startedAt: startedAt, attempt: 1)
            overlay.show(model: self)
            try await beginCapture(restarting: false)
            scheduleArmingTimeout(startedAt: startedAt, attempt: 1)
            maximumRecordingTask?.cancel()
            maximumRecordingTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(maximumDuration))
                guard !Task.isCancelled, self.isCapturing else { return }
                self.stopRecording()
            }
            scheduleModelPreloadIfAllowed()
        } catch {
            isMicrophoneTest = false
            alertMessage = error.localizedDescription
            returnToIdle()
        }
    }

    func stopRecording() {
        guard isCapturing else { return }
        armingTimeoutTask?.cancel()
        maximumRecordingTask?.cancel()
        performanceTracker?.markProcessingStarted()
        phase = .processing(.preparingAudio)
        overlay.update(model: self)
        processingTask = Task { [weak self] in
            guard let self else { return }
            let recording = await recorder.stop()
            guard !recording.samples.isEmpty else {
                recordCaptureFailure(recording, message: "\(recording.deviceName) seçildi fakat mikrofon 0 ses paketi üretti.")
                return
            }
            if isMicrophoneTest {
                lastAudioDiagnostics = recording.diagnostics
                isMicrophoneTest = false
                audioLevels = [Float](repeating: 0, count: 34)
                _ = performanceTracker?.finish()
                pasteService.notify("Mikrofon testi tamamlandı", recording.diagnostics.summary)
                returnToIdle()
                return
            }
            await process(recording: recording)
        }
    }

    func cancel() {
        if case .processing(.askingCodex) = phase {
            Task { await codex.cancel() }
            return
        }
        armingTimeoutTask?.cancel(); maximumRecordingTask?.cancel()
        recorder.stopImmediately(); cancelModelPreload(); processingTask?.cancel()
        releaseWhisperModel(reason: "cancel")
        returnToIdle()
    }

    func shutdown() {
        hotKey.unregister(); recorder.stopImmediately(); modelStore.cancelDownload()
        armingTimeoutTask?.cancel(); maximumRecordingTask?.cancel()
        cancelModelPreload(); processingTask?.cancel(); modelReleaseTask?.cancel()
        memoryPressureTask?.cancel(); memoryPressureTask = nil
        memoryPressureMonitor?.cancel(); memoryPressureMonitor = nil
        performanceTracker = nil
        breadcrumbStore.clear()
        Task { await codex.cancel(); await whisper.unload(); await speechSegmenter.unload() }
        phase = .idle
        overlay.hide()
    }

    func applyHotKey(_ candidate: HotKeyConfiguration) -> Bool {
        do { try installHotKey(candidate); settings.hotKey = candidate; return true }
        catch { alertMessage = error.localizedDescription; return false }
    }

    func setLoginAtStartup(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginAtStartup = enabled
        } catch { alertMessage = "Login başlangıcı değiştirilemedi: \(error.localizedDescription)" }
    }

    func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            Task {
                _ = await recorder.requestPermission()
                microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
            }
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .authorized:
            microphonePermission = .authorized
        @unknown default:
            break
        }
    }

    func resetCodexConversation() { settings.codexThreadID = nil; pasteService.notify("Yeni Codex konuşması", "Bir sonraki uzun kayıt yeni bir konuşma başlatacak.") }
    func copyLastResult() { if let lastResult { _ = pasteService.copyAndOptionallyPaste(lastResult, shouldPaste: false) } }
    func copy(_ text: String) { _ = pasteService.copyAndOptionallyPaste(text, shouldPaste: false) }

    private func installHotKey(_ configuration: HotKeyConfiguration) throws {
        try hotKey.register(configuration) { [weak self] in self?.toggleRecording() }
    }

    private func process(recording: AudioCapture) async {
        var diagnostics = recording.diagnostics
        var chunkDiagnostics: [ChunkTranscriptionDiagnostic] = []
        do {
            performanceTracker?.begin("Ses hazırlama")
            setStage(.preparingAudio)
            let prepared = await Task.detached(priority: .userInitiated) {
                AudioPreprocessor.prepare(recording)
            }.value
            try Task.checkCancellation()
            let allSamples = AudioPreprocessor.resample(recording.samples, from: recording.sampleRate,
                                                        to: AudioPreprocessor.targetRate)

            performanceTracker?.begin("Konuşma algılama")
            setStage(.segmentingSpeech)
            var chunks: [SpeechChunk] = []
            do {
                let vadURL = try await vadModelStore.modelURL()
                let segmentation = try await speechSegmenter.segment(samples: allSamples, modelURL: vadURL)
                diagnostics.vadSegmentCount = segmentation.segmentCount
                diagnostics.transcriptionChunkCount = segmentation.chunks.count
                diagnostics.vadSpeechDuration = segmentation.speechDuration
                if segmentation.chunks.isEmpty {
                    guard !prepared.samples.isEmpty, prepared.voicedDuration >= 0.20 else {
                        throw DikteError.noSpeech
                    }
                    diagnostics.vadFallbackReason = "VAD konuşma bulamadı; enerji tabanlı bütün ses kullanıldı."
                    chunks = [SpeechChunk(samples: prepared.samples, sourceStartSample: 0,
                                          sourceEndSample: allSamples.count,
                                          speechSampleCount: Int(prepared.voicedDuration * 16_000))]
                    diagnostics.transcriptionChunkCount = 1
                } else {
                    chunks = segmentation.chunks
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch DikteError.noSpeech {
                throw DikteError.noSpeech
            } catch {
                guard !prepared.samples.isEmpty, prepared.voicedDuration >= 0.20 else {
                    throw DikteError.noSpeech
                }
                diagnostics.vadFallbackReason = error.localizedDescription
                diagnostics.vadSpeechDuration = prepared.voicedDuration
                diagnostics.transcriptionChunkCount = 1
                chunks = [SpeechChunk(samples: prepared.samples, sourceStartSample: 0,
                                      sourceEndSample: allSamples.count,
                                      speechSampleCount: Int(prepared.voicedDuration * 16_000))]
            }
            try Task.checkCancellation()

            performanceTracker?.begin("Model hazırlama")
            setStage(.preparingModel)
            if case .missing = modelStore.status { throw DikteError.modelMissing }
            guard case .ready = modelStore.status else { throw DikteError.modelMissing }
            if let releaseTask = modelReleaseTask { await releaseTask.value }
            try Task.checkCancellation()
            try await whisper.load(modelURL: AppPaths.model)
            modelStore.isLoaded = true
            breadcrumbStore.update(modelLoaded: true)

            setStage(.transcribing)
            let detectedSpeechDuration = diagnostics.vadSpeechDuration > 0 ? diagnostics.vadSpeechDuration : prepared.voicedDuration
            var selectedParts: [WhisperTranscript] = []
            var hasUnresolvedChunk = false

            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                performanceTracker?.begin("Whisper parça \(index + 1)")
                let firstStarted = DispatchTime.now().uptimeNanoseconds
                let primary = try await whisper.transcribe(samples: chunk.samples, language: settings.language,
                                                           promptTerms: corrections.promptTerms)
                let firstMilliseconds = elapsedMilliseconds(since: firstStarted)
                let retryReason = ChunkAcceptancePolicy.issue(for: primary, speechDuration: chunk.speechDuration)
                var selectedPart = primary
                var retry: WhisperTranscript?
                var retryMilliseconds: Double?
                var recovered = false

                if retryReason != nil {
                    setStage(.retryingTranscription)
                    performanceTracker?.begin("Whisper retry \(index + 1)")
                    let lower = max(0, min(chunk.sourceStartSample, allSamples.count))
                    let upper = max(lower, min(chunk.sourceEndSample, allSamples.count))
                    let originalTimeline = Array(allSamples[lower..<upper])
                    let retryStarted = DispatchTime.now().uptimeNanoseconds
                    let retryLanguage: RecognitionLanguage = settings.language == .automatic ? .turkish : settings.language
                    let value = try await whisper.transcribe(samples: originalTimeline, language: retryLanguage,
                                                             promptTerms: corrections.promptTerms,
                                                             noSpeechThreshold: 0.35)
                    retryMilliseconds = elapsedMilliseconds(since: retryStarted)
                    retry = value
                    if ChunkAcceptancePolicy.issue(for: value, speechDuration: chunk.speechDuration) == nil {
                        selectedPart = value
                        recovered = true
                    } else {
                        hasUnresolvedChunk = true
                        selectedPart = value.tokenCount > primary.tokenCount ? value : primary
                    }
                    setStage(.transcribing)
                }

                selectedParts.append(selectedPart)
                chunkDiagnostics.append(ChunkTranscriptionDiagnostic(
                    index: index, sourceStart: Double(chunk.sourceStartSample) / 16_000,
                    sourceEnd: Double(chunk.sourceEndSample) / 16_000,
                    speechDuration: chunk.speechDuration, firstPassText: primary.text,
                    firstPassConfidence: primary.meanTokenProbability,
                    firstPassTokenCount: primary.tokenCount, detectedLanguage: primary.detectedLanguage,
                    firstPassMilliseconds: firstMilliseconds, retryReason: retryReason,
                    retryText: retry?.text, retryConfidence: retry?.meanTokenProbability,
                    retryTokenCount: retry?.tokenCount, retryMilliseconds: retryMilliseconds,
                    selectedText: selectedPart.text, recovered: recovered
                ))
            }

            var selected = aggregateTranscripts(selectedParts)
            if hasUnresolvedChunk {
                performanceTracker?.begin("Bütün kayıt fallback")
                setStage(.retryingTranscription)
                let retryLanguage: RecognitionLanguage = settings.language == .automatic ? .turkish : settings.language
                let whole = try await whisper.transcribe(samples: allSamples, language: retryLanguage,
                                                         promptTerms: corrections.promptTerms,
                                                         noSpeechThreshold: 0.35)
                if ChunkAcceptancePolicy.issue(for: whole, speechDuration: detectedSpeechDuration) == nil {
                    selected = whole
                    hasUnresolvedChunk = false
                    diagnostics.vadFallbackReason = "Eksik Whisper parçası bütün kayıt fallback’i ile kurtarıldı."
                }
            }

            let raw = selected.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard TranscriptionPolicy.accepts(raw, voicedDuration: detectedSpeechDuration) else {
                throw DikteError.noSpeech
            }
            if hasUnresolvedChunk {
                finishIncomplete(recording, partialText: raw, diagnostics: diagnostics,
                                 chunkDiagnostics: chunkDiagnostics)
                return
            }

            performanceTracker?.begin("Metin temizleme")
            setStage(.cleaning)
            let cleaned = TextCleaner.clean(raw)
            let localResult = cleaned
            var final = localResult; var response: String?; var codexError: String?
            let useCodex = RoutePolicy.shouldUseCodex(duration: recording.duration, threshold: settings.codexThreshold)
            if useCodex {
                performanceTracker?.begin("Codex")
                setStage(.askingCodex)
                do {
                    let oldThreadID = settings.codexThreadID
                    let result: CodexResult
                    do {
                        result = try await askCodex(localResult, threadID: oldThreadID)
                    } catch {
                        guard oldThreadID != nil, isMissingThreadError(error) else { throw error }
                        settings.codexThreadID = nil
                        pasteService.notify("Codex konuşması yenileniyor", "Eski konuşma bulunamadı; yeni konuşma açıldı.")
                        result = try await askCodex(localResult, threadID: nil)
                    }
                    settings.codexThreadID = result.threadID; response = result.text; final = result.text
                } catch {
                    codexError = error.localizedDescription
                }
            }
            performanceTracker?.begin("Pano ve yapıştırma")
            setStage(.copying)
            lastResult = final
            _ = pasteService.copyAndOptionallyPaste(final, shouldPaste: settings.automaticPaste)
            diagnostics.voicedDuration = detectedSpeechDuration
            let performance = performanceTracker?.finish()
            let wordsPerSecond = Double(raw.split(whereSeparator: \Character.isWhitespace).count) / max(0.001, detectedSpeechDuration)
            let charactersPerSecond = Double(raw.filter { !$0.isWhitespace }.count) / max(0.001, detectedSpeechDuration)
            history.add(HistoryEntry(duration: recording.duration, mode: useCodex ? .autoAsk : .dictation,
                                     rawTranscript: raw, finalText: final, deterministicText: cleaned,
                                     localCorrectedText: nil, primaryConfidence: selected.meanTokenProbability,
                                     lowConfidenceTokenRatio: selected.lowConfidenceTokenRatio,
                                     wordsPerSecond: wordsPerSecond, charactersPerSecond: charactersPerSecond,
                                     codexResponse: response, codexError: codexError,
                                     audioDiagnostics: diagnostics, chunkDiagnostics: chunkDiagnostics,
                                     performanceDiagnostics: performance))
            returnToIdle()
        } catch is CancellationError {
            returnToIdle()
        } catch DikteError.noSpeech {
            finishWithoutSpeech(recording, diagnostics: diagnostics)
        } catch {
            recordCaptureFailure(recording, message: error.localizedDescription, diagnostics: diagnostics)
        }
    }

    private func setStage(_ stage: ProcessingStage) { phase = .processing(stage); overlay.update(model: self) }

    private func receiveAudioLevel(_ level: Float) {
        guard isRecording else { return }
        audioLevels.removeFirst()
        audioLevels.append(level)
    }

    private func beginCapture(restarting: Bool) async throws {
        try await recorder.start(restarting: restarting) { [weak self] in
            self?.receiveFirstAudioSample()
        } onLevel: { [weak self] level in
            self?.receiveAudioLevel(level)
        }
    }

    private func receiveFirstAudioSample() {
        guard case .arming(let startedAt, _) = phase else { return }
        armingTimeoutTask?.cancel()
        phase = .recording(startedAt: startedAt)
        overlay.update(model: self)
    }

    private func scheduleArmingTimeout(startedAt: Date, attempt: Int) {
        armingTimeoutTask?.cancel()
        armingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled,
                  case .arming(_, let currentAttempt) = self.phase,
                  currentAttempt == attempt else { return }
            if attempt == 1 {
                do {
                    self.phase = .arming(startedAt: startedAt, attempt: 2)
                    self.overlay.update(model: self)
                    try await self.beginCapture(restarting: true)
                    self.scheduleArmingTimeout(startedAt: startedAt, attempt: 2)
                } catch {
                    let capture = await self.recorder.stop()
                    self.recordCaptureFailure(capture, message: error.localizedDescription)
                }
            } else {
                let capture = await self.recorder.stop()
                self.recordCaptureFailure(capture, message: "MacBook mikrofonu iki denemede de ses paketi üretmedi.")
            }
        }
    }

    private func recordCaptureFailure(_ capture: AudioCapture, message: String, diagnostics: AudioDiagnostics? = nil) {
        let effectiveDiagnostics = diagnostics ?? capture.diagnostics
        let detail = effectiveDiagnostics.summary
        lastAudioDiagnostics = effectiveDiagnostics
        isMicrophoneTest = false
        history.add(HistoryEntry(duration: capture.duration, mode: .recordingError,
                                 rawTranscript: "", finalText: message,
                                 deterministicText: nil, localCorrectedText: nil,
                                 audioDiagnostics: effectiveDiagnostics,
                                 performanceDiagnostics: performanceTracker?.finish()))
        alertMessage = detail.isEmpty ? message : "\(message)\n\n\(detail)"
        returnToIdle()
    }

    private func finishWithoutSpeech(_ capture: AudioCapture, diagnostics: AudioDiagnostics) {
        lastAudioDiagnostics = diagnostics
        isMicrophoneTest = false
        history.add(HistoryEntry(duration: capture.duration, mode: .recordingError,
                                 rawTranscript: "", finalText: "Ses yok.",
                                 deterministicText: nil, localCorrectedText: nil,
                                 audioDiagnostics: diagnostics,
                                 performanceDiagnostics: performanceTracker?.finish()))
        pasteService.notify("Dikte", "Ses yok.")
        returnToIdle()
    }

    private func finishIncomplete(_ capture: AudioCapture, partialText: String,
                                  diagnostics: AudioDiagnostics,
                                  chunkDiagnostics: [ChunkTranscriptionDiagnostic]) {
        let cleaned = TextCleaner.clean(partialText)
        if !cleaned.isEmpty {
            lastResult = cleaned
            _ = pasteService.copyAndOptionallyPaste(cleaned, shouldPaste: false)
        }
        let performance = performanceTracker?.finish()
        history.add(HistoryEntry(duration: capture.duration, mode: .incomplete,
                                 rawTranscript: partialText, finalText: cleaned,
                                 deterministicText: cleaned, localCorrectedText: nil,
                                 audioDiagnostics: diagnostics, chunkDiagnostics: chunkDiagnostics,
                                 performanceDiagnostics: performance))
        pasteService.notify("Dikte", "Bir konuşma bölümü çözülemedi; bulunan metin panoda.")
        returnToIdle()
    }

    private func aggregateTranscripts(_ parts: [WhisperTranscript]) -> WhisperTranscript {
        let tokenCount = parts.reduce(0) { $0 + $1.tokenCount }
        let weightedConfidence = parts.reduce(Float(0)) {
            $0 + $1.meanTokenProbability * Float($1.tokenCount)
        }
        let weakTokens = parts.reduce(Float(0)) {
            $0 + $1.lowConfidenceTokenRatio * Float($1.tokenCount)
        }
        return WhisperTranscript(
            text: TranscriptAssembler.join(parts.map(\.text)),
            meanTokenProbability: tokenCount > 0 ? weightedConfidence / Float(tokenCount) : 0,
            lowConfidenceTokenRatio: tokenCount > 0 ? weakTokens / Float(tokenCount) : 0,
            tokenCount: tokenCount,
            detectedLanguage: parts.compactMap(\.detectedLanguage).first
        )
    }

    private func elapsedMilliseconds(since startedAt: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
    }

    private func configureMemoryPressureHandling() {
        let monitor = MemoryPressureMonitor()
        memoryPressureMonitor = monitor
        memoryPressureTask = Task { @MainActor [weak self, events = monitor.events] in
            for await level in events {
                guard !Task.isCancelled, let self else { return }
                self.handleMemoryPressure(level)
            }
        }
    }

    private func handleMemoryPressure(_ level: MemoryPressureLevel) {
        memoryPressureLevel = level
        breadcrumbStore.update(modelLoaded: modelStore.isLoaded, memoryPressureLevel: level)
        Self.lifecycleLog.notice("Memory pressure changed: \(level.rawValue, privacy: .public); phase: \(self.phase.diagnosticName, privacy: .public)")

        switch MemoryPressurePolicy.action(for: level, phase: phase) {
        case .none:
            break
        case .releaseNow:
            cancelModelPreload()
            if phase != .idle { pendingMemoryRelease = true }
            Self.lifecycleLog.notice("Whisper release requested immediately for memory pressure")
            releaseWhisperModel(reason: "memory-pressure-\(level.rawValue)")
        case .deferRelease:
            pendingMemoryRelease = true
            Self.lifecycleLog.notice("Whisper release deferred until processing returns to idle")
        }
    }

    private func scheduleModelPreloadIfAllowed() {
        guard memoryPressureLevel == .normal else {
            Self.lifecycleLog.notice("Whisper preload skipped while memory pressure is active")
            return
        }
        guard case .ready = modelStore.status else { return }
        cancelModelPreload()
        modelPreloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await whisper.load(modelURL: AppPaths.model)
                try Task.checkCancellation()
                guard memoryPressureLevel == .normal, isCapturing || isProcessing else {
                    await whisper.unload()
                    modelStore.isLoaded = false
                    breadcrumbStore.update(modelLoaded: false)
                    modelPreloadTask = nil
                    return
                }
                modelStore.isLoaded = true
                breadcrumbStore.update(modelLoaded: true)
            } catch is CancellationError {
                await whisper.unload()
                modelStore.isLoaded = false
                breadcrumbStore.update(modelLoaded: false)
            } catch {
                Self.lifecycleLog.error("Whisper preload failed: \(error.localizedDescription, privacy: .public)")
            }
            modelPreloadTask = nil
        }
    }

    private func cancelModelPreload() {
        modelPreloadTask?.cancel()
        modelPreloadTask = nil
    }

    private func releaseWhisperModel(reason: String) {
        guard modelReleaseTask == nil else { return }
        modelReleaseTask = Task { [weak self] in
            guard let self else { return }
            await whisper.unload()
            modelStore.isLoaded = false
            breadcrumbStore.update(modelLoaded: false)
            Self.lifecycleLog.notice("Whisper model released: \(reason, privacy: .public)")
            modelReleaseTask = nil
        }
    }

    private func returnToIdle() {
        armingTimeoutTask?.cancel()
        maximumRecordingTask?.cancel()
        performanceTracker = nil
        processingTask = nil
        phase = .idle
        overlay.hide()
        breadcrumbStore.clear()

        if MemoryPressurePolicy.shouldReleaseOnReturnToIdle(
            pending: pendingMemoryRelease,
            level: memoryPressureLevel
        ) {
            pendingMemoryRelease = false
            Self.lifecycleLog.notice("Applying pending Whisper release on return to idle")
            releaseWhisperModel(reason: "return-to-idle")
        }
    }

    private func recoverUnexpectedCrash() {
        guard let breadcrumb = breadcrumbStore.recover() else { return }
        breadcrumbStore.clear()
        let duration = max(0, Date().timeIntervalSince(breadcrumb.startedAt))
        let detail = "Beklenmedik kapanış · aşama: \(breadcrumb.stage) · model: \(breadcrumb.modelLoaded ? "yüklü" : "kapalı") · bellek baskısı: \(breadcrumb.memoryPressureLevel.rawValue)"
        history.add(HistoryEntry(duration: duration, mode: .recordingError,
                                 rawTranscript: "", finalText: detail,
                                 codexError: "Session \(breadcrumb.sessionID.uuidString)"))
        Self.lifecycleLog.error("Recovered unfinished session \(breadcrumb.sessionID.uuidString, privacy: .public) at \(breadcrumb.stage, privacy: .public)")
    }

    private func removeLegacyAccurateModel() {
        let names = ["ggml-large-v3-q5_0.bin", "ggml-large-v3-q5_0.bin.part"]
        for name in names {
            try? FileManager.default.removeItem(at: AppPaths.models.appendingPathComponent(name))
        }
    }

    private func askCodex(_ text: String, threadID: String?) async throws -> CodexResult {
        try await withTimeout(seconds: 120) {
            try await self.codex.ask(transcript: text, existingThreadID: threadID) { id in
                Task { @MainActor in self.settings.codexThreadID = id }
            }
        }
    }

    private func isMissingThreadError(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("thread") || text.contains("session") || text.contains("conversation") || text.contains("not found")
    }
}

private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: .seconds(seconds)); throw DikteError.message("Codex zaman aşımına uğradı.") }
        guard let first = try await group.next() else { throw CancellationError() }
        group.cancelAll(); return first
    }
}
