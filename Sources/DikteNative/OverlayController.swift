import AppKit
import SwiftUI

enum OverlayLayout {
    static let compactSize = NSSize(width: 286, height: 46)
    static let wideSize = NSSize(width: 520, height: 72)
    static let compactInset = NSPoint(x: 28, y: 24)

    static func frame(position: OverlayPosition, visibleFrame: NSRect) -> NSRect {
        let size = position.isCompact ? compactSize : wideSize
        let origin: NSPoint
        if position == .top {
            origin = NSPoint(x: visibleFrame.midX - size.width / 2,
                             y: visibleFrame.maxY - size.height - 4)
        } else {
            origin = NSPoint(x: visibleFrame.minX + compactInset.x,
                             y: visibleFrame.minY + compactInset.y)
        }
        return NSRect(origin: origin, size: size)
    }
}

@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private var activeScreen: NSScreen?

    func show(model: AppModel) {
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: OverlayView(model: model))
            self.panel = panel
        }
        if activeScreen == nil { activeScreen = screenUnderPointer() ?? NSScreen.main }
        resizeAndPosition(model.settings.overlayPosition)
        panel?.orderFrontRegardless()
    }

    func update(model: AppModel) { show(model: model) }

    func hide() {
        panel?.orderOut(nil)
        activeScreen = nil
    }

    private func resizeAndPosition(_ position: OverlayPosition) {
        guard let screen = activeScreen ?? NSScreen.main, let panel else { return }
        let target = OverlayLayout.frame(position: position, visibleFrame: screen.visibleFrame)
        panel.setContentSize(target.size)
        panel.setFrameOrigin(target.origin)
    }

    private func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}

private struct OverlayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.settings.overlayPosition.isCompact { compactView } else { wideView }
        }
        .background(.ultraThickMaterial,
                    in: RoundedRectangle(cornerRadius: model.settings.overlayPosition.isCompact ? 13 : 16))
    }

    private var compactView: some View {
        Group {
            if model.isCapturing { compactRecordingView } else { compactProcessingView }
        }
        .padding(.horizontal, 11)
        .frame(width: 286, height: 46)
    }

    private var compactRecordingView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRecording ? .orange : .secondary)
                .frame(width: 9, height: 9)
                .shadow(color: model.isRecording ? .orange.opacity(0.7) : .clear, radius: 4)
                .accessibilityLabel(recordingTitle)
            CompactWaveform(levels: model.audioLevels)
            recordingTimer.frame(width: 42, alignment: .trailing)
            Button(action: model.stopRecording) {
                Image(systemName: "stop.fill").font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Kaydı durdur")
        }
        .help("\(recordingTitle) · \(model.recorder.builtInInputName)")
    }

    private var compactProcessingView: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small).frame(width: 15, height: 15)
            Text(processingTitle).font(.caption.weight(.medium)).lineLimit(1)
            Spacer(minLength: 4)
            Button(action: model.cancel) {
                Image(systemName: "xmark").font(.caption.bold()).frame(width: 22, height: 22)
            }.buttonStyle(.plain).help("İşlemi iptal et")
        }
    }

    private var wideView: some View {
        Group {
            if model.isCapturing { wideRecordingView } else { wideProcessingView }
        }
        .padding(.horizontal, 16)
        .frame(width: 520, height: 72)
    }

    private var wideRecordingView: some View {
        HStack(spacing: 12) {
            Circle().fill(model.isRecording ? .orange : .secondary).frame(width: 10, height: 10)
                .shadow(color: model.isRecording ? .orange.opacity(0.7) : .clear, radius: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(recordingTitle).font(.caption.bold())
                Text(model.recorder.builtInInputName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: 145, alignment: .leading)
            LiveWaveform(levels: model.audioLevels)
            recordingTimer
            Button(action: model.stopRecording) { Image(systemName: "stop.fill") }
                .buttonStyle(.borderless).help("Kaydı durdur")
        }
    }

    @ViewBuilder private var recordingTimer: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            Text(elapsed(at: context.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var recordingTitle: String {
        if model.isArming { return "Mikrofon hazırlanıyor…" }
        return (model.audioLevels.max() ?? 0) > 0.015 ? "Dinliyorum…" : "Ses bekleniyor"
    }

    private func elapsed(at date: Date) -> String {
        let start: Date
        switch model.phase {
        case .arming(let value, _), .recording(let value): start = value
        default: return "0:00"
        }
        let seconds = max(0, date.timeIntervalSince(start))
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private var wideProcessingView: some View {
        HStack(spacing: 12) {
            Image(systemName: "ellipsis.circle.fill").font(.system(size: 25)).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(processingTitle).font(.headline)
                Text("İşlem iptal edilebilir").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: model.cancel) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
    }

    private var processingTitle: String {
        switch model.phase {
        case .idle: "Hazır"
        case .arming: "Mikrofon hazırlanıyor…"
        case .recording: "Dinliyorum…"
        case .processing(let stage): stage.title
        }
    }
}

private struct CompactWaveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.suffix(18).enumerated()), id: \.offset) { _, level in
                Capsule().fill(.primary.opacity(0.72))
                    .frame(width: 2.5, height: max(2.5, CGFloat(level) * 26))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .animation(.easeOut(duration: 0.1), value: levels)
        .accessibilityLabel("Canlı mikrofon ses seviyesi")
    }
}

private struct LiveWaveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule().fill(.primary.opacity(0.72))
                    .frame(width: 3, height: max(3, CGFloat(level) * 38))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 42)
        .animation(.easeOut(duration: 0.1), value: levels)
        .accessibilityLabel("Canlı mikrofon ses seviyesi")
    }
}
