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
    @Published private(set) var lastAudioDiagnostics: AudioDiagnostics?
    @Published private(set) var isMicrophoneTest = false
    @Published private(set) var diagnosticCaptureArmed = false
    @Published private(set) var captureMode: CaptureMode = .general

    let settings = AppSettings()
    let history = HistoryStore()
    let modelStore = ModelStore()
    let vadModelStore = VADModelStore()
    let corrections = CorrectionStore()
    let diagnosticStore = WhisperDiagnosticStore()
    let audioMeter = AudioMeterState()
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
    private var modelLifecycleGeneration = 0
    private let modelIdleReleaseScheduler = ModelIdleReleaseScheduler()
    private var memoryPressureLevel: MemoryPressureLevel = .normal
    private var pendingMemoryRelease = false
    private var activeDiagnosticCapture = false
    private var diagnosticCaptureArm = OneShotDiagnosticCaptureArm()
    private var isStartingCapture = false
    private var audioLevelSink: AudioLevelSink?
    private let breadcrumbStore = CrashBreadcrumbStore()
    private let overlay = OverlayController()
    private static let lifecycleLog = Logger(subsystem: "com.turkerdenizer.dikte.native", category: "Lifecycle")

    init() {
        recoverUnexpectedCrash()
        removeLegacyAccurateModel()
        loginAtStartup = SMAppService.mainApp.status == .enabled
        if settings.hotKey.matchesShortcut(settings.codingHotKey) {
            settings.hotKey = .optionD
            settings.codingHotKey = .optionE
            alertMessage = "İki kısayol aynı kombinasyona ayarlanmıştı; varsayılanlara (⌥D / ⌥E) döndürüldü."
        }
        do {
            if try !installHotKeys(general: settings.hotKey, coding: settings.codingHotKey) {
                alertMessage = "Kısa ve Net kısayolu (\(settings.codingHotKey.displayName)) kaydedilemedi. Ham kısayolu çalışmaya devam ediyor."
            }
        } catch {
            alertMessage = error.localizedDescription
        }
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
        await startCapture(maximumDuration: settings.maximumRecording, mode: .general)
    }

    private func handleHotKey(_ mode: CaptureMode) {
        switch CaptureHotKeyPolicy.action(for: phase, activeMode: captureMode,
                                          requestedMode: mode, isStarting: isStartingCapture) {
        case .start(let mode):
            Task { await startRecording(mode: mode) }
        case .stop:
            stopRecording()
        case .ignore:
            break
        }
    }

    private func startRecording(mode: CaptureMode) async {
        isMicrophoneTest = false
        await startCapture(maximumDuration: settings.maximumRecording, mode: mode)
    }

    func startMicrophoneTest() {
        guard phase == .idle, !isStartingCapture else {
            if isMicrophoneTest && isCapturing { stopRecording() }
            return
        }
        isMicrophoneTest = true
        Task { await startCapture(maximumDuration: 5, mode: .general) }
    }

    private func startCapture(maximumDuration: TimeInterval, mode: CaptureMode) async {
        guard phase == .idle, !isStartingCapture else { return }
        isStartingCapture = true
        captureMode = mode
        let microphoneGranted = await recorder.requestPermission()
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
        guard phase == .idle, isStartingCapture else {
            isStartingCapture = false
            return
        }
        guard microphoneGranted else {
            isStartingCapture = false
            isMicrophoneTest = false
            captureMode = .general
            alertMessage = "Mikrofon izni verilmedi. General bölümündeki Mikrofon İzni düğmesinden Sistem Ayarları’nı açabilirsin."
            return
        }
        modelIdleReleaseScheduler.cancel()
        do {
            let startedAt = Date()
            breadcrumbStore.begin(stage: "arming-1", modelLoaded: modelStore.isLoaded,
                                  memoryPressureLevel: memoryPressureLevel)
            performanceTracker = PerformanceTracker()
            performanceTracker?.begin("Kayıt")
            audioLevelSink = audioMeter.start()
            phase = .arming(startedAt: startedAt, attempt: 1)
            overlay.show(model: self)
            try await beginCapture(restarting: false)
            guard isCapturing else {
                isStartingCapture = false
                return
            }
            isStartingCapture = false
            activeDiagnosticCapture = diagnosticCaptureArm.consume(isMicrophoneTest: isMicrophoneTest)
            diagnosticCaptureArmed = diagnosticCaptureArm.isArmed
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
            isStartingCapture = false
            isMicrophoneTest = false
            alertMessage = error.localizedDescription
            captureMode = .general
            returnToIdle()
        }
    }

    func stopRecording() {
        guard isCapturing else { return }
        armingTimeoutTask?.cancel()
        maximumRecordingTask?.cancel()
        performanceTracker?.markProcessingStarted()
        let mode = captureMode
        phase = .processing(.preparingAudio)
        overlay.update(model: self)
        processingTask = Task { [weak self] in
            guard let self else { return }
            let recording = await recorder.stop()
            guard !recording.samples.isEmpty else {
                await recordCaptureFailure(recording, message: "\(recording.deviceName) seçildi fakat mikrofon 0 ses paketi üretti.", mode: mode)
                return
            }
            if isMicrophoneTest {
                lastAudioDiagnostics = recording.diagnostics
                isMicrophoneTest = false
                _ = finishPerformance()
                pasteService.notify("Mikrofon testi tamamlandı", recording.diagnostics.summary)
                returnToIdle()
                return
            }
            await process(recording: recording, mode: mode)
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
        isStartingCapture = false
        armingTimeoutTask?.cancel(); maximumRecordingTask?.cancel()
        cancelModelPreload(); processingTask?.cancel(); modelReleaseTask?.cancel()
        modelIdleReleaseScheduler.cancel()
        memoryPressureTask?.cancel(); memoryPressureTask = nil
        memoryPressureMonitor?.cancel(); memoryPressureMonitor = nil
        performanceTracker = nil
        audioLevelSink = nil
        audioMeter.stop()
        breadcrumbStore.clear()
        Task { await codex.cancel(); await whisper.unload(); await speechSegmenter.unload() }
        phase = .idle
        overlay.hide()
    }

    func applyHotKey(_ candidate: HotKeyConfiguration, for mode: CaptureMode) -> Bool {
        let general = mode == .general ? candidate : settings.hotKey
        let coding = mode == .coding ? candidate : settings.codingHotKey
        guard !general.matchesShortcut(coding) else {
            alertMessage = "Ham ve Kısa ve Net kısayolları aynı kombinasyon olamaz."
            return false
        }
        do {
            let codingRegistered = try installHotKeys(general: general, coding: coding)
            settings.hotKey = general
            // A failed Coding registration leaves the previous one active, so the
            // stored value must keep matching what is actually registered.
            if codingRegistered {
                settings.codingHotKey = coding
            } else {
                alertMessage = "Kısa ve Net kısayolu (\(coding.displayName)) kaydedilemedi; başka bir uygulama kullanıyor olabilir. Önceki kısayol korundu."
            }
            return mode == .general ? true : codingRegistered
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
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
    func resetCodingCodexConversation() {
        settings.codingCodexThreadID = nil
        pasteService.notify("Yeni Kısa ve Net konuşması", "Bir sonraki Kısa ve Net kaydı yeni bir konuşma başlatacak.")
    }
    func copyLastResult() { if let lastResult { _ = pasteService.copyAndOptionallyPaste(lastResult, shouldPaste: false) } }
    func copy(_ text: String) { _ = pasteService.copyAndOptionallyPaste(text, shouldPaste: false) }
    func toggleDiagnosticCapture() {
        guard phase == .idle else { return }
        diagnosticCaptureArm.toggle()
        diagnosticCaptureArmed = diagnosticCaptureArm.isArmed
        let message = diagnosticCaptureArmed
            ? "Yalnız bir sonraki normal kayıt geçici tanı verisiyle saklanacak."
            : "Tanı kaydı iptal edildi."
        pasteService.notify("Whisper tanısı", message)
    }
    func revealDiagnosticCapture(id: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([diagnosticStore.audioURL(for: id)])
    }
    func deleteDiagnosticCapture(id: UUID) { Task { await diagnosticStore.delete(id: id) } }
    func deleteAllDiagnosticCaptures() { Task { await diagnosticStore.deleteAll() } }

    private func installHotKeys(general: HotKeyConfiguration, coding: HotKeyConfiguration) throws -> Bool {
        try hotKey.register(general: general, coding: coding) { [weak self] mode in
            self?.handleHotKey(mode)
        }
    }

    private func process(recording: AudioCapture, mode: CaptureMode) async {
        var diagnostics = recording.diagnostics
        var chunkDiagnostics: [ChunkTranscriptionDiagnostic] = []
        var vadRegions: [SpeechRegion] = []
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
                vadRegions = segmentation.regions
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
            let modelLoadStartedAt = DispatchTime.now().uptimeNanoseconds
            try await whisper.load(modelURL: AppPaths.model)
            performanceTracker?.recordModelLoad(
                milliseconds: elapsedMilliseconds(since: modelLoadStartedAt)
            )
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
                await finishIncomplete(recording, partialText: raw, diagnostics: diagnostics,
                                       vadRegions: vadRegions, chunkDiagnostics: chunkDiagnostics, mode: mode)
                return
            }

            performanceTracker?.begin("Metin temizleme")
            setStage(.cleaning)
            let cleanedRaw = TextCleaner.clean(raw)
            let (cleaned, appliedCorrectionIDs) = TextCleaner.applyCorrections(cleanedRaw, entries: corrections.entries)
            corrections.recordApplied(appliedCorrectionIDs)
            let localResult = cleaned
            var final = localResult; var response: String?; var codexError: String?
            let route = RoutePolicy.destination(for: mode, duration: recording.duration,
                                                threshold: settings.codexThreshold)
            let useCodex = route == .codex
            if useCodex {
                performanceTracker?.begin("Codex")
                setStage(.askingCodex)
                do {
                    let oldThreadID = codexThreadID(for: mode)
                    let result: CodexResult
                    do {
                        result = try await askCodex(localResult, threadID: oldThreadID, mode: mode)
                    } catch {
                        guard oldThreadID != nil, isMissingThreadError(error) else { throw error }
                        setCodexThreadID(nil, for: mode)
                        pasteService.notify("Codex konuşması yenileniyor", "Eski konuşma bulunamadı; yeni konuşma açıldı.")
                        result = try await askCodex(localResult, threadID: nil, mode: mode)
                    }
                    setCodexThreadID(result.threadID, for: mode)
                    response = result.text; final = result.text
                } catch {
                    codexError = error.localizedDescription
                }
            }
            performanceTracker?.begin("Pano ve yapıştırma")
            setStage(.copying)
            lastResult = final
            _ = pasteService.copyAndOptionallyPaste(final, shouldPaste: settings.automaticPaste)
            diagnostics.voicedDuration = detectedSpeechDuration
            let performance = finishPerformance()
            let wordsPerSecond = Double(raw.split(whereSeparator: \Character.isWhitespace).count) / max(0.001, detectedSpeechDuration)
            let charactersPerSecond = Double(raw.filter { !$0.isWhitespace }.count) / max(0.001, detectedSpeechDuration)
            let historyID = UUID()
            let historyMode: HistoryMode = useCodex ? .autoAsk : .dictation
            let diagnosticID = await persistDiagnosticIfNeeded(
                recording: recording, historyEntryID: historyID, mode: historyMode,
                diagnostics: diagnostics, vadRegions: vadRegions, chunkDiagnostics: chunkDiagnostics,
                rawTranscript: raw, deterministicText: cleaned, finalText: final
            )
            history.add(HistoryEntry(id: historyID, duration: recording.duration, mode: historyMode,
                                     captureMode: mode,
                                     rawTranscript: raw, finalText: final, deterministicText: cleaned,
                                     localCorrectedText: nil, primaryConfidence: selected.meanTokenProbability,
                                     lowConfidenceTokenRatio: selected.lowConfidenceTokenRatio,
                                     wordsPerSecond: wordsPerSecond, charactersPerSecond: charactersPerSecond,
                                     codexResponse: response, codexError: codexError,
                                     audioDiagnostics: diagnostics, chunkDiagnostics: chunkDiagnostics,
                                     performanceDiagnostics: performance,
                                     diagnosticCaptureID: diagnosticID))
            returnToIdle()
        } catch is CancellationError {
            returnToIdle()
        } catch DikteError.noSpeech {
            await finishWithoutSpeech(recording, diagnostics: diagnostics, vadRegions: vadRegions, mode: mode)
        } catch {
            await recordCaptureFailure(recording, message: error.localizedDescription,
                                       diagnostics: diagnostics, vadRegions: vadRegions,
                                       chunkDiagnostics: chunkDiagnostics, mode: mode)
        }
    }

    private func setStage(_ stage: ProcessingStage) { phase = .processing(stage); overlay.update(model: self) }

    private func beginCapture(restarting: Bool) async throws {
        guard let audioLevelSink else {
            throw DikteError.message("Ses seviyesi hattı hazırlanamadı.")
        }
        try await recorder.start(restarting: restarting) { [weak self] in
            self?.receiveFirstAudioSample()
        } onLevel: { [audioLevelSink] level in
            audioLevelSink.yield(level)
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
                    await self.recordCaptureFailure(capture, message: error.localizedDescription, mode: self.captureMode)
                }
            } else {
                let capture = await self.recorder.stop()
                await self.recordCaptureFailure(capture, message: "MacBook mikrofonu iki denemede de ses paketi üretmedi.", mode: self.captureMode)
            }
        }
    }

    private func recordCaptureFailure(_ capture: AudioCapture, message: String,
                                      diagnostics: AudioDiagnostics? = nil,
                                      vadRegions: [SpeechRegion] = [],
                                      chunkDiagnostics: [ChunkTranscriptionDiagnostic] = [],
                                      mode: CaptureMode? = nil) async {
        let effectiveDiagnostics = diagnostics ?? capture.diagnostics
        let detail = effectiveDiagnostics.summary
        lastAudioDiagnostics = effectiveDiagnostics
        isMicrophoneTest = false
        let historyID = UUID()
        let diagnosticID = await persistDiagnosticIfNeeded(
            recording: capture, historyEntryID: historyID, mode: .recordingError,
            diagnostics: effectiveDiagnostics, vadRegions: vadRegions,
            chunkDiagnostics: chunkDiagnostics, rawTranscript: "",
            deterministicText: nil, finalText: message
        )
        history.add(HistoryEntry(id: historyID, duration: capture.duration, mode: .recordingError,
                                 captureMode: mode,
                                 rawTranscript: "", finalText: message,
                                 deterministicText: nil, localCorrectedText: nil,
                                 audioDiagnostics: effectiveDiagnostics,
                                 performanceDiagnostics: finishPerformance(),
                                 diagnosticCaptureID: diagnosticID))
        alertMessage = detail.isEmpty ? message : "\(message)\n\n\(detail)"
        returnToIdle()
    }

    private func finishWithoutSpeech(_ capture: AudioCapture, diagnostics: AudioDiagnostics,
                                     vadRegions: [SpeechRegion], mode: CaptureMode) async {
        lastAudioDiagnostics = diagnostics
        isMicrophoneTest = false
        let historyID = UUID()
        let diagnosticID = await persistDiagnosticIfNeeded(
            recording: capture, historyEntryID: historyID, mode: .recordingError,
            diagnostics: diagnostics, vadRegions: vadRegions, chunkDiagnostics: [],
            rawTranscript: "", deterministicText: nil, finalText: "Ses yok."
        )
        history.add(HistoryEntry(id: historyID, duration: capture.duration, mode: .recordingError,
                                 captureMode: mode,
                                 rawTranscript: "", finalText: "Ses yok.",
                                 deterministicText: nil, localCorrectedText: nil,
                                 audioDiagnostics: diagnostics,
                                 performanceDiagnostics: finishPerformance(),
                                 diagnosticCaptureID: diagnosticID))
        pasteService.notify(notificationTitle(for: mode), "Ses yok.")
        returnToIdle()
    }

    private func finishIncomplete(_ capture: AudioCapture, partialText: String,
                                  diagnostics: AudioDiagnostics,
                                  vadRegions: [SpeechRegion],
                                  chunkDiagnostics: [ChunkTranscriptionDiagnostic],
                                  mode: CaptureMode) async {
        let cleanedRaw = TextCleaner.clean(partialText)
        let (cleaned, appliedCorrectionIDs) = TextCleaner.applyCorrections(cleanedRaw, entries: corrections.entries)
        corrections.recordApplied(appliedCorrectionIDs)
        if !cleaned.isEmpty {
            lastResult = cleaned
            _ = pasteService.copyAndOptionallyPaste(cleaned, shouldPaste: false)
        }
        let performance = finishPerformance()
        let historyID = UUID()
        let diagnosticID = await persistDiagnosticIfNeeded(
            recording: capture, historyEntryID: historyID, mode: .incomplete,
            diagnostics: diagnostics, vadRegions: vadRegions,
            chunkDiagnostics: chunkDiagnostics, rawTranscript: partialText,
            deterministicText: cleaned, finalText: cleaned
        )
        history.add(HistoryEntry(id: historyID, duration: capture.duration, mode: .incomplete,
                                 captureMode: mode,
                                 rawTranscript: partialText, finalText: cleaned,
                                 deterministicText: cleaned, localCorrectedText: nil,
                                 audioDiagnostics: diagnostics, chunkDiagnostics: chunkDiagnostics,
                                 performanceDiagnostics: performance,
                                 diagnosticCaptureID: diagnosticID))
        pasteService.notify(notificationTitle(for: mode), "Bir konuşma bölümü çözülemedi; bulunan metin panoda.")
        returnToIdle()
    }

    private func notificationTitle(for mode: CaptureMode) -> String {
        mode == .coding ? mode.title : "Dikte"
    }

    private func persistDiagnosticIfNeeded(
        recording: AudioCapture, historyEntryID: UUID, mode: HistoryMode,
        diagnostics: AudioDiagnostics, vadRegions: [SpeechRegion],
        chunkDiagnostics: [ChunkTranscriptionDiagnostic], rawTranscript: String,
        deterministicText: String?, finalText: String
    ) async -> UUID? {
        guard activeDiagnosticCapture else { return nil }
        do {
            let id = try await diagnosticStore.save(
                recording: recording, historyEntryID: historyEntryID, mode: mode,
                audioDiagnostics: diagnostics, vadRegions: vadRegions,
                chunkDiagnostics: chunkDiagnostics, rawTranscript: rawTranscript,
                deterministicText: deterministicText, finalText: finalText
            )
            pasteService.notify("Whisper tanısı kaydedildi", "Ses ve tanı verileri geçici Diagnostics klasörüne yazıldı.")
            return id
        } catch {
            pasteService.notify("Whisper tanısı kaydedilemedi", error.localizedDescription)
            return nil
        }
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

    private func finishPerformance() -> PerformanceDiagnostics? {
        guard let performanceTracker else { return nil }
        performanceTracker.recordVisualDiagnostics(
            audioMeter: audioMeter.statistics(),
            overlay: overlay.trackingStatistics()
        )
        return performanceTracker.finish()
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
        modelLifecycleGeneration += 1
        let generation = modelLifecycleGeneration
        modelPreloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await whisper.load(modelURL: AppPaths.model)
                try Task.checkCancellation()
                guard generation == modelLifecycleGeneration,
                      memoryPressureLevel == .normal, isCapturing || isProcessing else {
                    if generation == modelLifecycleGeneration {
                        await whisper.unload()
                        modelStore.isLoaded = false
                        breadcrumbStore.update(modelLoaded: false)
                        modelPreloadTask = nil
                    }
                    return
                }
                modelStore.isLoaded = true
                breadcrumbStore.update(modelLoaded: true)
            } catch is CancellationError {
                if generation == modelLifecycleGeneration {
                    await whisper.unload()
                    modelStore.isLoaded = false
                    breadcrumbStore.update(modelLoaded: false)
                }
            } catch {
                Self.lifecycleLog.error("Whisper preload failed: \(error.localizedDescription, privacy: .public)")
            }
            if generation == modelLifecycleGeneration { modelPreloadTask = nil }
        }
    }

    private func cancelModelPreload() {
        modelLifecycleGeneration += 1
        modelPreloadTask?.cancel()
        modelPreloadTask = nil
    }

    private func releaseWhisperModel(reason: String) {
        modelIdleReleaseScheduler.cancel()
        guard modelReleaseTask == nil else { return }
        cancelModelPreload()
        modelLifecycleGeneration += 1
        modelReleaseTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = DispatchTime.now().uptimeNanoseconds
            await whisper.unload()
            await speechSegmenter.unload()
            performanceTracker?.recordModelUnload(
                milliseconds: elapsedMilliseconds(since: startedAt)
            )
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
        isStartingCapture = false
        activeDiagnosticCapture = false
        audioLevelSink = nil
        audioMeter.stop()
        phase = .idle
        overlay.hide()
        captureMode = .general
        breadcrumbStore.clear()

        if MemoryPressurePolicy.shouldReleaseOnReturnToIdle(
            pending: pendingMemoryRelease,
            level: memoryPressureLevel
        ) {
            pendingMemoryRelease = false
            Self.lifecycleLog.notice("Applying pending Whisper release on return to idle")
            releaseWhisperModel(reason: "return-to-idle")
        } else if modelStore.isLoaded {
            modelIdleReleaseScheduler.schedule(after: ModelLifecyclePolicy.warmModelSeconds) { [weak self] in
                guard let self, self.phase == .idle else { return }
                Self.lifecycleLog.notice("Applying Whisper release after idle timeout")
                self.releaseWhisperModel(reason: "idle-timeout")
            }
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

    private func codexThreadID(for mode: CaptureMode) -> String? {
        switch mode {
        case .general: settings.codexThreadID
        case .coding: settings.codingCodexThreadID
        }
    }

    private func setCodexThreadID(_ threadID: String?, for mode: CaptureMode) {
        switch mode {
        case .general: settings.codexThreadID = threadID
        case .coding: settings.codingCodexThreadID = threadID
        }
    }

    private func askCodex(_ text: String, threadID: String?, mode: CaptureMode) async throws -> CodexResult {
        let promptKind: CodexPromptKind = mode == .coding ? .concise : .editing
        return try await withTimeout(seconds: 120) {
            try await self.codex.ask(transcript: text, existingThreadID: threadID, promptKind: promptKind) { id in
                Task { @MainActor in self.setCodexThreadID(id, for: mode) }
            }
        }
    }

    private func isMissingThreadError(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("thread") || text.contains("session") || text.contains("conversation") || text.contains("not found")
    }
}

enum ModelLifecyclePolicy {
    static let warmModelSeconds: TimeInterval = 45
}

private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: .seconds(seconds)); throw DikteError.message("Codex zaman aşımına uğradı.") }
        guard let first = try await group.next() else { throw CancellationError() }
        group.cancelAll(); return first
    }
}
