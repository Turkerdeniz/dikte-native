import AppKit
import AVFoundation
import Carbon
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var modelStore: ModelStore
    @ObservedObject private var history: HistoryStore

    init(model: AppModel) {
        self.model = model; settings = model.settings; modelStore = model.modelStore; history = model.history
    }

    var body: some View {
        TabView {
            GeneralSettingsView(model: model).tabItem { Label("General", systemImage: "gearshape") }
            LocalModelSettingsView(model: model).tabItem { Label("Local Model", systemImage: "cpu") }
            CodexSettingsView(model: model).tabItem { Label("Codex", systemImage: "sparkles") }
            HistoryView(model: model).tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 610)
        .preferredColorScheme(.dark)
        .alert("Dikte", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("Tamam") { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
    }
}

private struct SectionCard<Content: View>: View {
    let title: String; @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline); content
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08)))
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var diagnosticStore: WhisperDiagnosticStore
    @ObservedObject private var audioMeter: AudioMeterState
    @State private var recordingHotKey = false
    @State private var confirmDeleteDiagnostics = false
    init(model: AppModel) {
        self.model = model
        settings = model.settings
        diagnosticStore = model.diagnosticStore
        audioMeter = model.audioMeter
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionCard("Kayıt") {
                    HStack {
                        Text("Mikrofon")
                        Spacer()
                        Label(model.recorder.builtInInputName, systemImage: "laptopcomputer")
                            .foregroundStyle(.secondary)
                    }
                    Text("Dikte her zaman MacBook’un yerleşik mikrofonunu kullanır; Bluetooth kulaklığın ses kalitesi etkilenmez.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.isMicrophoneTest ? (model.isArming ? "Mikrofon hazırlanıyor…" : "Canlı seviye") : "Mikrofon testi")
                                .font(.caption)
                            ProgressView(value: Double(audioMeter.levels.max() ?? 0), total: 1)
                                .frame(width: 220)
                        }
                        Spacer()
                        Button(model.isMicrophoneTest && model.isCapturing ? "Testi bitir" : "5 sn test et") {
                            model.startMicrophoneTest()
                        }.disabled(model.isProcessing && !model.isMicrophoneTest)
                    }
                    if let diagnostics = model.lastAudioDiagnostics {
                        Text(diagnostics.summary).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Picker("Dil", selection: $settings.language) { ForEach(RecognitionLanguage.allCases) { Text($0.title).tag($0) } }
                    HStack { Text("Maksimum kayıt"); Spacer(); Text("\(Int(settings.maximumRecording / 60)) dakika").foregroundStyle(.secondary) }
                    Slider(value: $settings.maximumRecording, in: 60...300, step: 60)
                    Divider()
                    HStack {
                        Label(microphonePermissionTitle,
                              systemImage: model.microphonePermission == .authorized ? "checkmark.circle.fill" : "mic.slash.fill")
                            .foregroundStyle(model.microphonePermission == .authorized ? .green : .orange)
                        Spacer()
                        if model.microphonePermission != .authorized {
                            Button(model.microphonePermission == .notDetermined ? "İzin İste" : "Sistem Ayarlarını Aç") {
                                model.requestMicrophoneAccess()
                            }
                        }
                    }
                }
                SectionCard("Kısayol") {
                    HStack {
                        Text("General kısayolu"); Spacer()
                        Button(settings.hotKey.displayName) { recordingHotKey = true }.keyboardShortcut(.none)
                    }
                    HStack {
                        Text("Coding mode"); Spacer(); Text(HotKeyConfiguration.optionE.displayName).foregroundStyle(.secondary)
                    }
                    Text("Varsayılan General kısayolu ⌥D’dir. Coding mode için ⌥E sabittir; ikinci bir kısayol düzenleyicisi yoktur. Mikrofon/F5 tuşu kullanılmaz ve Erişilebilirlik izni gerekmez.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SectionCard("Pano ve görünüm") {
                    Toggle("Sonucu otomatik yapıştır", isOn: $settings.automaticPaste)
                    HStack {
                        Label(model.pasteService.accessibilityGranted ? "Erişilebilirlik izni verildi" : "Erişilebilirlik izni yok", systemImage: model.pasteService.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(model.pasteService.accessibilityGranted ? .green : .orange)
                        Spacer(); Button("İzin Ver") { model.pasteService.requestAccessibility() }
                    }
                    Picker("Overlay konumu", selection: $settings.overlayPosition) { ForEach(OverlayPosition.allCases) { Text($0.title).tag($0) } }
                    Toggle("Login’de başlat", isOn: Binding(get: { model.loginAtStartup }, set: { enabled in model.setLoginAtStartup(enabled) }))
                }
                SectionCard("Whisper tanısı") {
                    Label(model.diagnosticCaptureArmed ? "Sonraki kayıt tanı için işaretlendi" : "Tanı kaydı kapalı",
                          systemImage: model.diagnosticCaptureArmed ? "waveform.badge.mic" : "waveform.badge.minus")
                        .foregroundStyle(model.diagnosticCaptureArmed ? .orange : .secondary)
                    Text("Normal kullanımda ses diske yazılmaz. Bu işlem yalnız bir sonraki normal kaydın 16 kHz sesini ve Whisper tanısını geçici olarak saklar; mikrofon testi etkilenmez.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(model.diagnosticCaptureArmed ? "Tanı kaydını iptal et" : "Sonraki kaydı tanı için sakla") {
                        model.toggleDiagnosticCapture()
                    }
                    .disabled(model.phase != .idle)

                    if !diagnosticStore.captures.isEmpty {
                        Divider()
                        Text("\(diagnosticStore.captures.count) tanı kaydı · \(formatDiagnosticBytes(diagnosticStore.totalAudioBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(diagnosticStore.captures.prefix(5)) { capture in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("History: \(capture.historyEntryID.uuidString)")
                                    Text("\(capture.sampleRate) Hz · \(capture.sampleCount) örnek · \(capture.vadRegions.count) VAD bölümü · \(capture.chunkDiagnostics.count) Whisper parçası")
                                    if !capture.rawTranscript.isEmpty {
                                        Text(capture.rawTranscript).lineLimit(3).textSelection(.enabled)
                                    }
                                    HStack {
                                        Button("Finder’da göster") { model.revealDiagnosticCapture(id: capture.id) }
                                        Button("Sil", role: .destructive) { model.deleteDiagnosticCapture(id: capture.id) }
                                            .disabled(model.phase != .idle)
                                    }
                                }
                                .font(.caption)
                                .padding(.top, 6)
                            } label: {
                                Text("\(capture.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.1f sn", capture.duration))")
                            }
                        }
                        Button("Tüm tanı kayıtlarını sil", role: .destructive) { confirmDeleteDiagnostics = true }
                            .disabled(model.phase != .idle)
                    }
                }
            }.padding(20)
        }
        .sheet(isPresented: $recordingHotKey) { HotKeyCaptureSheet(model: model, isPresented: $recordingHotKey) }
        .confirmationDialog("Tüm geçici Whisper tanı kayıtları silinsin mi?", isPresented: $confirmDeleteDiagnostics) {
            Button("Tümünü sil", role: .destructive) { model.deleteAllDiagnosticCaptures() }
            Button("Vazgeç", role: .cancel) { }
        } message: {
            Text("History, model ve normal uygulama verileri korunur.")
        }
    }

    private var microphonePermissionTitle: String {
        switch model.microphonePermission {
        case .authorized: "Mikrofon izni verildi"
        case .notDetermined: "Mikrofon izni henüz istenmedi"
        case .denied: "Mikrofon izni reddedildi"
        case .restricted: "Mikrofon erişimi kısıtlı"
        @unknown default: "Mikrofon izni bilinmiyor"
        }
    }

    private func formatDiagnosticBytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}

private struct LocalModelSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: ModelStore
    @ObservedObject private var vadStore: VADModelStore
    @ObservedObject private var corrections: CorrectionStore
    init(model: AppModel) {
        self.model = model
        store = model.modelStore
        vadStore = model.vadModelStore
        corrections = model.corrections
    }
    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            SectionCard("Whisper · Large v3 Turbo Q5") {
                HStack { statusLabel; Spacer(); Text("547,4 MB").foregroundStyle(.secondary) }
                if case .downloading(let progress) = store.status {
                    ProgressView(value: progress); Button("İndirmeyi durdur") { store.cancelDownload() }
                } else if case .verifying = store.status { ProgressView().controlSize(.small); Text("SHA-256 doğrulanıyor…") }
                else if case .missing = store.status { Button("Modeli indir") { store.download() }.buttonStyle(.borderedProminent) }
                else if case .failed = store.status { HStack { Button("Yeniden dene") { store.download() }; Button("Parçayı temizle") { store.deleteModel() } } }
                if case .ready = store.status { Button("Modeli sil ve yeniden indir", role: .destructive) { store.deleteModel() } }
            }
            SectionCard("Bellek") {
                Label(store.isLoaded ? "Whisper bellekte ve hazır" : "Whisper bellekte değil",
                      systemImage: store.isLoaded ? "bolt.fill" : "moon")
                Text("Turbo modeli son kullanımdan \(Int(ModelLifecyclePolicy.warmModelSeconds)) saniye sonra veya bellek baskısında bırakılır.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SectionCard("Konuşma algılama · Silero VAD") {
                HStack { vadStatusLabel; Spacer(); Text("864,4 KB").foregroundStyle(.secondary) }
                Text("Her kayıtta uzun sessizlikleri ve konuşma dışı bölümleri ayırır. Gürültü azaltma uygulamaz ve ayrı bir süreç açmaz.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !corrections.entries.isEmpty {
                SectionCard("Doğrulanmış sözlük") {
                    ForEach(corrections.entries) { entry in
                        HStack {
                            Toggle("", isOn: Binding(get: { entry.isEnabled }, set: { corrections.setEnabled(id: entry.id, enabled: $0) }))
                                .labelsHidden()
                            Text("\(entry.heard) → \(entry.corrected)")
                            Spacer()
                            Button(role: .destructive) { corrections.delete(id: entry.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
          }.padding(20)
        }
    }
    @ViewBuilder private var vadStatusLabel: some View {
        switch vadStore.status {
        case .verifying: Label("Doğrulanıyor", systemImage: "checkmark.shield")
        case .ready: Label("Hazır", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
    @ViewBuilder private var statusLabel: some View {
        switch store.status {
        case .missing: Label("İndirilmedi", systemImage: "arrow.down.circle")
        case .downloading: Label("İndiriliyor", systemImage: "arrow.down.circle.fill")
        case .verifying: Label("Doğrulanıyor", systemImage: "checkmark.shield")
        case .ready: Label("Hazır", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

private struct CodexSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    init(model: AppModel) { self.model = model; settings = model.settings }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard("Codex durumu") {
                Label(CodexClient.executableURL() == nil ? "Codex bulunamadı" : "Codex hazır", systemImage: CodexClient.executableURL() == nil ? "xmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(CodexClient.executableURL() == nil ? .orange : .green)
                Text("Uzun konuşmalar yeni pencere açmadan, salt-okunur geçici bir Codex işlemiyle düzenlenir.").font(.caption).foregroundStyle(.secondary)
                Label("Sesli düşünce editörü etkin", systemImage: "text.badge.checkmark")
                    .font(.caption)
                Text("Codex konuşmayı cevaplamaz; anlamı ve doğal tonu koruyarak doğrudan yapıştırılabilir metne dönüştürür.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("Coding prompt compiler etkin", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption)
                Text("Coding mode, konuşmayı cevaplamadan yapılandırılmış bir coding prompt’una dönüştürür; dosya değiştirmez ve komut çalıştırmaz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SectionCard("Otomatik yönlendirme") {
                HStack { Text("Eşik"); Spacer(); Text(settings.codexThreshold == 0 ? "Kapalı" : String(format: "%.1f saniye", settings.codexThreshold)).monospacedDigit() }
                Slider(value: $settings.codexThreshold, in: 0...120, step: 0.1)
                Text("Yalnız süre eşikten kesin olarak uzunsa Codex kullanılır.").font(.caption).foregroundStyle(.secondary)
                Text("30 saniye ve daha kısa kayıtlar yalnız bu Mac’te temizlenir.").font(.caption).foregroundStyle(.secondary)
            }
            SectionCard("Kalıcı konuşma") {
                Text(settings.codexThreadID.map { "Aktif: \($0)" } ?? "Henüz konuşma oluşturulmadı").textSelection(.enabled).lineLimit(2)
                Button("Yeni konuşma", role: .destructive) { model.resetCodexConversation() }
            }
            SectionCard("Coding mode konuşması") {
                Text(settings.codingCodexThreadID.map { "Aktif: \($0)" } ?? "Henüz coding konuşması oluşturulmadı")
                    .textSelection(.enabled).lineLimit(2)
                Button("Yeni coding konuşması", role: .destructive) { model.resetCodingCodexConversation() }
            }
            Spacer()
        }.padding(20)
    }
}

private struct HistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: HistoryStore
    @ObservedObject private var diagnosticStore: WhisperDiagnosticStore
    @State private var selection: UUID?
    @State private var editingEntry: HistoryEntry?
    init(model: AppModel) {
        self.model = model
        store = model.history
        diagnosticStore = model.diagnosticStore
    }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(store.entries, selection: $selection) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(modeTitle(entry)).font(.caption).bold(); Spacer(); Text(entry.timestamp, style: .date).font(.caption2) }
                        Text(entry.finalText).lineLimit(2); Text(String(format: "%.1f sn", entry.duration)).font(.caption2).foregroundStyle(.secondary)
                    }.tag(entry.id)
                }
                HStack { Button("Tümünü sil", role: .destructive) { store.deleteAll(); selection = nil }; Spacer() }.padding(10)
            }.frame(minWidth: 260)
            if let entry = store.entries.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(entry.finalText).textSelection(.enabled).font(.title3)
                        HStack {
                            Button("Panoya kopyala") { model.copy(entry.finalText) }
                            if entry.mode != .recordingError { Button("Düzelt ve öğret") { editingEntry = entry } }
                            Button("Kaydı sil", role: .destructive) { store.delete(id: entry.id); selection = nil }
                        }
                        if let diagnosticID = entry.diagnosticCaptureID {
                            if diagnosticStore.captures.contains(where: { $0.id == diagnosticID }) {
                                Label("Geçici Whisper tanı kaydı bağlı", systemImage: "waveform.badge.mic")
                                    .font(.caption).foregroundStyle(.orange)
                                Button("Tanı klasörünü göster") { model.revealDiagnosticCapture(id: diagnosticID) }
                            } else {
                                Label("Bağlı tanı kaydı silinmiş", systemImage: "waveform.badge.minus")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if entry.mode != .recordingError {
                            Divider(); Text("Whisper’ın duyduğu").font(.headline); Text(entry.rawTranscript).textSelection(.enabled)
                            if let accurate = entry.accurateTranscript {
                                Divider(); Text("Güçlü modelin duyduğu").font(.headline); Text(accurate).textSelection(.enabled)
                                if let reason = entry.accuratePassReason {
                                    Text("İkinci geçiş: \(reason)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let confidence = entry.primaryConfidence {
                                Text(String(format: "Turbo güveni: %.0f%%", confidence * 100)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let ratio = entry.lowConfidenceTokenRatio {
                                Text(String(format: "Zayıf token oranı: %.0f%%", ratio * 100)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let words = entry.wordsPerSecond, let characters = entry.charactersPerSecond {
                                Text(String(format: "Konuşma yoğunluğu: %.2f kelime/sn · %.1f karakter/sn", words, characters))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let confidence = entry.accurateConfidence {
                                Text(String(format: "Large v3 güveni: %.0f%%", confidence * 100)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let selected = entry.accurateModelSelected {
                                Label(selected ? "Large v3 sonucu seçildi" : "Turbo sonucu korundu",
                                      systemImage: selected ? "checkmark.circle.fill" : "shield.fill")
                                    .font(.caption).foregroundStyle(selected ? .green : .secondary)
                            }
                            if let reason = entry.modelSelectionReason {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                            if let deterministic = entry.deterministicText {
                                Divider(); Text("Deterministik temizlik").font(.headline); Text(deterministic).textSelection(.enabled)
                            }
                            if let local = entry.localCorrectedText {
                                Divider(); Text("Yerel akıllı düzeltme").font(.headline); Text(local).textSelection(.enabled)
                            }
                        }
                        if let response = entry.codexResponse { Divider(); Text("Codex yanıtı").font(.headline); Text(response).textSelection(.enabled) }
                        if let error = entry.codexError { Divider(); Text("Codex hatası").font(.headline); Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                        if let diagnostics = entry.audioDiagnostics {
                            Divider(); Text("Ses tanısı").font(.headline)
                            Text(diagnostics.summary).font(.caption).textSelection(.enabled)
                            if diagnostics.vadSegmentCount > 0 || diagnostics.transcriptionChunkCount > 0 {
                                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                                    GridRow { Text("Gerçek kayıt").foregroundStyle(.secondary); Text(String(format: "%.1f sn", entry.duration)) }
                                    GridRow { Text("Algılanan konuşma").foregroundStyle(.secondary); Text(String(format: "%.1f sn", diagnostics.vadSpeechDuration)) }
                                    GridRow { Text("VAD bölümü").foregroundStyle(.secondary); Text("\(diagnostics.vadSegmentCount)") }
                                    GridRow { Text("Whisper parçası").foregroundStyle(.secondary); Text("\(diagnostics.transcriptionChunkCount)") }
                                }.font(.caption)
                            }
                            if let reason = diagnostics.vadFallbackReason {
                                Text("Fallback: \(reason)").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            }
                        }
                        if let chunks = entry.chunkDiagnostics, !chunks.isEmpty {
                            Divider(); Text("Whisper parçaları").font(.headline)
                            ForEach(chunks) { chunk in
                                DisclosureGroup("Parça \(chunk.index + 1) · \(String(format: "%.1f sn", chunk.speechDuration))") {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("İlk geçiş").font(.caption.bold())
                                        Text(chunk.firstPassText.isEmpty ? "Boş sonuç" : chunk.firstPassText)
                                            .font(.caption).textSelection(.enabled)
                                        Text(String(format: "Güven %.0f%% · %d token · %.0f ms",
                                                    chunk.firstPassConfidence * 100, chunk.firstPassTokenCount,
                                                    chunk.firstPassMilliseconds))
                                            .font(.caption2).foregroundStyle(.secondary)
                                        if let reason = chunk.retryReason {
                                            Text("Retry: \(reason)").font(.caption).foregroundStyle(.orange)
                                        }
                                        if let retryText = chunk.retryText {
                                            Text(retryText.isEmpty ? "Retry boş döndü" : retryText)
                                                .font(.caption).textSelection(.enabled)
                                        }
                                        if chunk.recovered {
                                            Label("Parça kurtarıldı", systemImage: "checkmark.circle.fill")
                                                .font(.caption).foregroundStyle(.green)
                                        }
                                    }.padding(.top, 6)
                                }
                            }
                        }
                        if let performance = entry.performanceDiagnostics {
                            Divider()
                            DisclosureGroup("Performans") {
                                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                                    GridRow { Text("Stop → sonuç").foregroundStyle(.secondary); Text(String(format: "%.0f ms", performance.totalMilliseconds)) }
                                    GridRow { Text("CPU zamanı").foregroundStyle(.secondary); Text(String(format: "%.0f ms kullanıcı + %.0f ms sistem", performance.userCPUMilliseconds, performance.systemCPUMilliseconds)) }
                                    GridRow { Text("Bellek").foregroundStyle(.secondary); Text("\(formatBytes(performance.residentBytesStart)) → \(formatBytes(performance.residentBytesEnd))") }
                                    GridRow { Text("Physical footprint").foregroundStyle(.secondary); Text("\(formatBytes(performance.physicalFootprintBytesStart)) → \(formatBytes(performance.physicalFootprintBytesEnd))") }
                                    GridRow { Text("Disk okuma/yazma").foregroundStyle(.secondary); Text("\(formatBytes(performance.diskReadBytes)) / \(formatBytes(performance.diskWrittenBytes))") }
                                    GridRow { Text("Thread").foregroundStyle(.secondary); Text("\(performance.threadCountStart) → \(performance.threadCountEnd)") }
                                    GridRow { Text("Termal durum").foregroundStyle(.secondary); Text(performance.thermalState) }
                                    if let received = performance.audioLevelReceivedCount,
                                       let rendered = performance.audioLevelRenderedCount,
                                       let coalesced = performance.audioLevelCoalescedCount {
                                        GridRow { Text("Ses seviyesi").foregroundStyle(.secondary); Text("\(received) alındı / \(rendered) çizildi / \(coalesced) birleştirildi") }
                                    }
                                    if let lag = performance.maximumAudioLevelLagMilliseconds {
                                        GridRow { Text("En yüksek görsel gecikme").foregroundStyle(.secondary); Text(String(format: "%.0f ms", lag)) }
                                    }
                                    if let queries = performance.overlayQueryCount,
                                       let skipped = performance.overlaySkippedQueryCount,
                                       let maximum = performance.maximumOverlayQueryMilliseconds {
                                        GridRow { Text("Ekran takibi").foregroundStyle(.secondary); Text(String(format: "%d sorgu / %d atlandı / en çok %.1f ms", queries, skipped, maximum)) }
                                    }
                                    if let load = performance.modelLoadMilliseconds {
                                        GridRow { Text("Model yükleme").foregroundStyle(.secondary); Text(String(format: "%.0f ms", load)) }
                                    }
                                    if let unload = performance.modelUnloadMilliseconds {
                                        GridRow { Text("Model bırakma").foregroundStyle(.secondary); Text(String(format: "%.0f ms", unload)) }
                                    }
                                }.font(.caption).padding(.vertical, 6)
                                ForEach(performance.stages) { stage in
                                    HStack { Text(stage.name); Spacer(); Text(String(format: "%.0f ms", stage.milliseconds)).monospacedDigit() }
                                        .font(.caption)
                                }
                            }
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { ContentUnavailableView("Bir kayıt seç", systemImage: "clock") }
        }
        .sheet(item: $editingEntry) { entry in
            CorrectionEditSheet(entry: entry, model: model)
        }
    }

    private func modeTitle(_ entry: HistoryEntry) -> String {
        if let captureMode = entry.captureMode {
            return captureMode == .coding ? "Coding" : "General"
        }
        switch entry.mode {
        case .dictation: return "Dikte"
        case .autoAsk: return "Codex"
        case .incomplete: return "Eksik kayıt"
        case .recordingError: return "Kayıt hatası"
        }
    }

    private func formatBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
}

private struct CorrectionEditSheet: View {
    let entry: HistoryEntry
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var correctedText: String
    @State private var candidates: [CorrectionCandidate] = []
    @State private var selected = Set<UUID>()

    init(entry: HistoryEntry, model: AppModel) {
        self.entry = entry
        self.model = model
        _correctedText = State(initialValue: entry.finalText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Düzelt ve öğret").font(.title2.bold())
            TextEditor(text: $correctedText).font(.body).frame(minHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
            if candidates.isEmpty {
                Text("Metni düzelt; ardından uygulamanın öğrenebileceği eşleşmeleri incele.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Yalnız onayladığın eşleşmeler sözlüğe eklenir.").font(.caption).foregroundStyle(.secondary)
                ForEach(candidates) { candidate in
                    Toggle("\(candidate.heard) → \(candidate.corrected)",
                           isOn: Binding(get: { selected.contains(candidate.id) }, set: {
                               if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                           }))
                }
            }
            HStack {
                Button("Vazgeç") { dismiss() }
                Spacer()
                if candidates.isEmpty {
                    Button("Eşleşmeleri incele") {
                        candidates = CorrectionLearner.candidates(original: entry.finalText, corrected: correctedText)
                        selected = Set(candidates.map(\.id))
                        if candidates.isEmpty { save() }
                    }.disabled(correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || correctedText == entry.finalText)
                } else {
                    Button("Kaydet ve öğret") { save() }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(24).frame(width: 560)
    }

    private func save() {
        model.history.correct(id: entry.id, text: correctedText)
        model.corrections.confirm(candidates.filter { selected.contains($0.id) })
        dismiss()
    }
}

private struct HotKeyCaptureSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var candidate: HotKeyConfiguration?
    var body: some View {
        VStack(spacing: 18) {
            Text("Yeni kısayola bas").font(.title2).bold()
            Text(candidate?.displayName ?? "⌘ / ⌥ / ⌃ / ⇧ + bir tuş").font(.system(size: 30, weight: .semibold, design: .rounded)).frame(height: 54)
            KeyCaptureView(candidate: $candidate)
            HStack { Button("Vazgeç") { isPresented = false }; Button("Kaydet") { if let candidate, model.applyHotKey(candidate) { isPresented = false } }.disabled(candidate == nil).buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 400, height: 230)
    }
}

private struct KeyCaptureView: NSViewRepresentable {
    @Binding var candidate: HotKeyConfiguration?
    func makeNSView(context: Context) -> CaptureNSView { let view = CaptureNSView(); view.onCapture = { candidate = $0 }; DispatchQueue.main.async { view.window?.makeFirstResponder(view) }; return view }
    func updateNSView(_ nsView: CaptureNSView, context: Context) { DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) } }
}

private final class CaptureNSView: NSView {
    var onCapture: ((HotKeyConfiguration) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control, .shift]).isEmpty, !event.isARepeat else { return }
        var carbon: UInt32 = 0; var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        let key = (event.charactersIgnoringModifiers ?? "?").uppercased()
        onCapture?(HotKeyConfiguration(keyCode: UInt32(event.keyCode), modifiers: carbon, displayName: symbols + key))
    }
}
