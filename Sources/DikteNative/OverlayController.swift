import AppKit
import CoreGraphics
import SwiftUI

struct OverlayDisplaySnapshot: Equatable, Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
}

struct OverlayWindowSnapshot: Equatable, Sendable {
    let ownerPID: pid_t
    let layer: Int
    let bounds: CGRect
}

enum OverlayScreenResolver {
    static let minimumWindowSize = CGSize(width: 120, height: 80)

    static func displayID(frontmostPID: pid_t?, currentDisplayID: CGDirectDisplayID?,
                          windows: [OverlayWindowSnapshot],
                          displays: [OverlayDisplaySnapshot]) -> CGDirectDisplayID? {
        guard !displays.isEmpty else { return nil }
        guard let frontmostPID,
              let window = windows.first(where: {
                  $0.ownerPID == frontmostPID && $0.layer == 0
                      && $0.bounds.width >= minimumWindowSize.width
                      && $0.bounds.height >= minimumWindowSize.height
              }) else { return nil }

        let overlaps = displays.map { display in
            (display.id, window.bounds.intersection(display.frame).standardizedArea)
        }
        guard let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        let windowArea = max(1, window.bounds.standardizedArea)

        if let currentDisplayID,
           displays.contains(where: { $0.id == currentDisplayID }),
           let currentOverlap = overlaps.first(where: { $0.0 == currentDisplayID })?.1 {
            if currentOverlap / windowArea >= 0.5 { return currentDisplayID }
            if best.1 / windowArea > 0.5 { return best.0 }
            return currentDisplayID
        }
        return best.0
    }
}

private extension CGRect {
    var standardizedArea: CGFloat {
        let rect = standardized
        guard !rect.isNull, !rect.isInfinite else { return 0 }
        return max(0, rect.width) * max(0, rect.height)
    }
}

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
    private weak var model: AppModel?
    private var activeDisplayID: CGDirectDisplayID?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObservers: [NSObjectProtocol] = []
    private var trackingTimer: Timer?
    private var trackingTask: Task<Void, Never>?
    private var trackingGeneration = 0
    private var trackingQueryCount = 0
    private var skippedTrackingQueryCount = 0
    private var maximumTrackingQueryMilliseconds = 0.0

    struct TrackingStatistics: Equatable, Sendable {
        let queryCount: Int
        let skippedQueryCount: Int
        let maximumQueryMilliseconds: Double
    }

    func trackingStatistics() -> TrackingStatistics {
        TrackingStatistics(queryCount: trackingQueryCount,
                           skippedQueryCount: skippedTrackingQueryCount,
                           maximumQueryMilliseconds: maximumTrackingQueryMilliseconds)
    }

    func show(model: AppModel) {
        self.model = model
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: OverlayView(model: model))
            self.panel = panel
        }
        let wasVisible = panel?.isVisible == true
        if !wasVisible { activeDisplayID = nil }
        refreshTargetScreen(animateWithinDisplay: wasVisible)
        panel?.orderFrontRegardless()
        startTracking()
    }

    func update(model: AppModel) { show(model: model) }

    func hide() {
        stopTracking()
        panel?.orderOut(nil)
        activeDisplayID = nil
        model = nil
    }

    private func resizeAndPosition(_ position: OverlayPosition, on screen: NSScreen,
                                   animateWithinDisplay: Bool) {
        guard let panel else { return }
        let targetDisplayID = Self.displayID(for: screen)
        let target = OverlayLayout.frame(position: position, visibleFrame: screen.visibleFrame)
        let sameDisplay = targetDisplayID != nil && targetDisplayID == activeDisplayID
        activeDisplayID = targetDisplayID
        guard !panel.frame.approximatelyEquals(target) else { return }
        if animateWithinDisplay && sameDisplay {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func refreshTargetScreen(animateWithinDisplay: Bool) {
        guard let model, let panel else { return }
        let screen = resolveTargetScreen() ?? NSScreen.main
        guard let screen else { return }
        resizeAndPosition(model.settings.overlayPosition, on: screen,
                          animateWithinDisplay: animateWithinDisplay)
        if panel.isVisible { panel.orderFrontRegardless() }
    }

    private func resolveTargetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let displays = screens.compactMap { screen -> OverlayDisplaySnapshot? in
            guard let id = Self.displayID(for: screen) else { return nil }
            return OverlayDisplaySnapshot(id: id, frame: CGDisplayBounds(id))
        }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let resolvedID = OverlayScreenResolver.displayID(
            frontmostPID: frontmostPID,
            currentDisplayID: activeDisplayID,
            windows: Self.visibleWindows(), displays: displays
        )
        if let resolvedID,
           let screen = screens.first(where: { Self.displayID(for: $0) == resolvedID }) {
            return screen
        }
        return screenUnderPointer() ?? screens.first(where: {
            Self.displayID(for: $0) == activeDisplayID
        }) ?? NSScreen.main
    }

    private func startTracking() {
        guard trackingTimer == nil else { return }
        trackingGeneration += 1
        trackingQueryCount = 0
        skippedTrackingQueryCount = 0
        maximumTrackingQueryMilliseconds = 0
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.pollTargetScreen() }
            })
        }
        applicationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTargetScreen(animateWithinDisplay: true)
                self?.pollTargetScreen()
            }
        })
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollTargetScreen() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func stopTracking() {
        trackingGeneration += 1
        trackingTask?.cancel()
        trackingTask = nil
        trackingTimer?.invalidate()
        trackingTimer = nil
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()
        applicationObservers.forEach(NotificationCenter.default.removeObserver)
        applicationObservers.removeAll()
    }

    private func pollTargetScreen() {
        guard panel?.isVisible == true else { return }
        guard trackingTask == nil else {
            skippedTrackingQueryCount += 1
            return
        }
        let generation = trackingGeneration
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let currentDisplayID = activeDisplayID
        let displays = NSScreen.screens.compactMap { screen -> OverlayDisplaySnapshot? in
            guard let id = Self.displayID(for: screen) else { return nil }
            return OverlayDisplaySnapshot(id: id, frame: CGDisplayBounds(id))
        }
        trackingTask = Task { @MainActor [weak self] in
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let windows = await Task.detached(priority: .utility) {
                Self.visibleWindows()
            }.value
            let resolvedID = OverlayScreenResolver.displayID(
                frontmostPID: frontmostPID, currentDisplayID: currentDisplayID,
                windows: windows, displays: displays
            )
            guard let self else { return }
            guard generation == self.trackingGeneration else { return }
            self.trackingTask = nil
            guard !Task.isCancelled,
                  self.panel?.isVisible == true else { return }
            self.trackingQueryCount += 1
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            self.maximumTrackingQueryMilliseconds = max(self.maximumTrackingQueryMilliseconds,
                                                         milliseconds)
            guard let resolvedID, resolvedID != self.activeDisplayID,
                  let screen = NSScreen.screens.first(where: {
                      Self.displayID(for: $0) == resolvedID
                  }), let model = self.model else { return }
            self.resizeAndPosition(model.settings.overlayPosition, on: screen,
                                   animateWithinDisplay: false)
            self.panel?.orderFrontRegardless()
        }
    }

    private func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    nonisolated private static func visibleWindows() -> [OverlayWindowSnapshot] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary else {
                return nil
            }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary as CFDictionary, &bounds) else {
                return nil
            }
            return OverlayWindowSnapshot(ownerPID: ownerPID.int32Value,
                                         layer: layer.intValue, bounds: bounds)
        }
    }
}

private extension NSRect {
    func approximatelyEquals(_ other: NSRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(size.width - other.size.width) <= tolerance
            && abs(size.height - other.size.height) <= tolerance
    }
}

private struct OverlayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var meter: AudioMeterState

    init(model: AppModel) {
        self.model = model
        meter = model.audioMeter
    }

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
            CompactWaveform(levels: meter.levels)
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
            LiveWaveform(levels: meter.levels)
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
        return (meter.levels.max() ?? 0) > 0.015 ? "Dinliyorum…" : "Ses bekleniyor"
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
        WaveformCanvas(levels: Array(levels.suffix(18)), barWidth: 2.5, spacing: 2,
                       minimumHeight: 2.5, amplitude: 26)
        .frame(maxWidth: .infinity, minHeight: 28)
        .accessibilityLabel("Canlı mikrofon ses seviyesi")
    }
}

private struct LiveWaveform: View {
    let levels: [Float]

    var body: some View {
        WaveformCanvas(levels: levels, barWidth: 3, spacing: 2.5,
                       minimumHeight: 3, amplitude: 38)
        .frame(maxWidth: .infinity, minHeight: 42)
        .accessibilityLabel("Canlı mikrofon ses seviyesi")
    }
}

private struct WaveformCanvas: View {
    let levels: [Float]
    let barWidth: CGFloat
    let spacing: CGFloat
    let minimumHeight: CGFloat
    let amplitude: CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard !levels.isEmpty else { return }
            let totalWidth = CGFloat(levels.count) * barWidth
                + CGFloat(max(0, levels.count - 1)) * spacing
            var x = max(0, (size.width - totalWidth) / 2)
            for level in levels {
                let height = max(minimumHeight, CGFloat(level) * amplitude)
                let rect = CGRect(x: x, y: (size.height - height) / 2,
                                  width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(.primary.opacity(0.72)))
                x += barWidth + spacing
            }
        }
    }
}
