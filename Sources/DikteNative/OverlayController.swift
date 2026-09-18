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

/// Places the waveform's bars from wall-clock time rather than from the arrival
/// of meter ticks.
///
/// The audio clock and the display clock never agree. Measured on a 120 fps
/// capture of the compact pill, a new bar entered every 17-67 ms instead of
/// every 33 ms, and ten times over seventeen seconds the strip stalled and then
/// caught up two or three bars at once. Nothing moved vertically — the pill, the
/// mode dot, the timer and the bar centres held to within 0.05 px across all
/// 2029 frames — so the flicker was this lurch, not a layout shift.
///
/// Deriving the offset from `now - lastSampleAt` makes the motion a function of
/// time alone: a late tick becomes a bar whose *height* lands late, which is
/// invisible, instead of a jump in the scroll, which is not.
struct WaveformGeometry: Equatable, Sendable {
    let barWidth: CGFloat
    let spacing: CGFloat

    var pitch: CGFloat { barWidth + spacing }

    /// Bars needed to cover `width`, plus the one sliding in past the edge.
    func barCount(forWidth width: CGFloat) -> Int {
        guard width > 0, pitch > 0 else { return 0 }
        return Int((width / pitch).rounded(.up)) + 1
    }

    /// How far the strip has slid since the newest bar entered.
    ///
    /// Clamped to one pitch: if the meter stalls, the strip parks instead of
    /// drifting away from the bars it is drawing. The gap that opens at the
    /// trailing edge during a stall is narrower than the edge fade, so it is
    /// never seen.
    func scrollOffset(since lastSampleAt: Date, at now: Date,
                      interval: TimeInterval) -> CGFloat {
        guard interval > 0 else { return 0 }
        let progress = now.timeIntervalSince(lastSampleAt) / interval
        return pitch * CGFloat(min(1, max(0, progress)))
    }

    /// Leading edge of the bar `index` places back from the newest one.
    func x(forIndexFromNewest index: Int, width: CGFloat, offset: CGFloat) -> CGFloat {
        width - offset - barWidth - CGFloat(index) * pitch
    }
}

/// Drives the overlay's entrance.
///
/// The microphone is not live the instant the hotkey fires: the capture session
/// still has to be built and started, and speech in that window is lost. The
/// pill used to appear immediately and so invited talking into that gap. It now
/// waits out most of it and eases in, which makes the entrance finishing the
/// cue that it is safe to start.
@MainActor
final class OverlayRevealState: ObservableObject {
    static let delay = Duration.milliseconds(150)
    static let duration: TimeInterval = 0.18

    @Published var isRevealed = false
}

/// Whether the overlay intends to be on screen, which leads `panel.isVisible`
/// by the length of the entrance delay.
///
/// Reading the intent off the panel instead made every phase change that landed
/// inside that delay look like a fresh presentation, and `receiveFirstAudioSample()`
/// lands there whenever the microphone comes up in under 150 ms. The entrance
/// restarted and the pill arrived another 150 ms late — the opposite of the
/// point of the delay.
struct OverlayPresentationState: Equatable, Sendable {
    private(set) var isPresenting = false

    /// True when this is a new presentation rather than an update to one
    /// already under way.
    mutating func show() -> Bool {
        defer { isPresenting = true }
        return !isPresenting
    }

    mutating func hide() { isPresenting = false }
}

@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private weak var model: AppModel?
    private let reveal = OverlayRevealState()
    private var presentation = OverlayPresentationState()
    private var revealTask: Task<Void, Never>?
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
            panel.contentView = NSHostingView(rootView: OverlayView(model: model, reveal: reveal))
            self.panel = panel
        }
        let isEntrance = presentation.show()
        if isEntrance { activeDisplayID = nil }
        refreshTargetScreen(animateWithinDisplay: !isEntrance)
        if isEntrance {
            beginReveal()
        } else if panel?.isVisible == true {
            // Still inside the entrance delay? Leave it alone; ordering the
            // panel in here is exactly what the delay exists to prevent.
            panel?.orderFrontRegardless()
        }
        startTracking()
    }

    func update(model: AppModel) { show(model: model) }

    func hide() {
        presentation.hide()
        revealTask?.cancel()
        revealTask = nil
        reveal.isRevealed = false
        stopTracking()
        panel?.orderOut(nil)
        activeDisplayID = nil
        model = nil
    }

    /// Ordering the panel in is what is delayed, not just its opacity: a panel
    /// held on screen at zero alpha still takes its shadow and its tracking
    /// area with it.
    private func beginReveal() {
        revealTask?.cancel()
        reveal.isRevealed = false
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: OverlayRevealState.delay)
            guard !Task.isCancelled, let self, self.model != nil else { return }
            self.panel?.orderFrontRegardless()
            withAnimation(.easeOut(duration: OverlayRevealState.duration)) {
                self.reveal.isRevealed = true
            }
        }
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
    @ObservedObject var reveal: OverlayRevealState
    @ObservedObject private var meter: AudioMeterState

    init(model: AppModel, reveal: OverlayRevealState) {
        self.model = model
        self.reveal = reveal
        meter = model.audioMeter
    }

    var body: some View {
        Group {
            if model.settings.overlayPosition.isCompact { compactView } else { wideView }
        }
        .background(.ultraThickMaterial,
                    in: RoundedRectangle(cornerRadius: model.settings.overlayPosition.isCompact ? 13 : 16))
        // Opacity and a centred scale only: the pill's frame is fixed, so the
        // entrance cannot move anything on the Y axis.
        .opacity(reveal.isRevealed ? 1 : 0)
        .scaleEffect(reveal.isRevealed ? 1 : 0.94)
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
            modeIndicator
            CompactWaveform(levels: meter.levels, lastSampleAt: meter.lastSampleAt,
                            isLive: model.isRecording)
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
            modeIndicator
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
            modeIndicator
            VStack(alignment: .leading, spacing: 1) {
                Text(recordingTitle).font(.caption.bold())
                Text(model.recorder.builtInInputName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: 145, alignment: .leading)
            LiveWaveform(levels: meter.levels, lastSampleAt: meter.lastSampleAt,
                         isLive: model.isRecording)
            // Without a fixed width the timer resizes the row at 0:09 -> 0:10.
            recordingTimer.frame(width: 42, alignment: .trailing)
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
        // The history is longer than the title's question needs; asking all of it
        // would keep "Dinliyorum…" up for two seconds after the room went quiet.
        return (meter.levels.suffix(34).max() ?? 0) > 0.015 ? "Dinliyorum…" : "Ses bekleniyor"
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
            modeIndicator
            VStack(alignment: .leading, spacing: 2) {
                Text(processingTitle).font(.headline)
                Text("İşlem iptal edilebilir").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: model.cancel) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
    }

    private var modeIndicator: some View {
        Circle()
            .fill(modeColor.opacity(model.isCapturing && !model.isRecording ? 0.55 : 1))
            .frame(width: 10, height: 10)
            .shadow(color: model.isRecording ? modeColor.opacity(0.7) : .clear, radius: 4)
            .accessibilityLabel(modeAccessibilityLabel)
    }

    private var modeColor: Color {
        model.captureMode == .coding ? .red : .orange
    }

    private var modeAccessibilityLabel: String {
        model.captureMode == .coding ? "Kısa ve Net modu" : "Ham modu"
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
    let lastSampleAt: Date
    let isLive: Bool

    var body: some View {
        WaveformCanvas(levels: levels, lastSampleAt: lastSampleAt,
                       geometry: WaveformGeometry(barWidth: 2.5, spacing: 2),
                       minimumHeight: 2.5, amplitude: 26, isLive: isLive)
        .frame(maxWidth: .infinity, minHeight: 28)
        .accessibilityLabel("Canlı mikrofon ses seviyesi")
    }
}

private struct LiveWaveform: View {
    let levels: [Float]
    let lastSampleAt: Date
    let isLive: Bool

    var body: some View {
        WaveformCanvas(levels: levels, lastSampleAt: lastSampleAt,
                       geometry: WaveformGeometry(barWidth: 3, spacing: 2.5),
                       minimumHeight: 3, amplitude: 38, isLive: isLive)
        .frame(maxWidth: .infinity, minHeight: 42)
        .accessibilityLabel("Canlı mikrofon ses seviyesi")
    }
}

private struct WaveformCanvas: View {
    let levels: [Float]
    let lastSampleAt: Date
    let geometry: WaveformGeometry
    let minimumHeight: CGFloat
    let amplitude: CGFloat
    let isLive: Bool

    var body: some View {
        // The display's own clock, not the meter's. The strip advances by
        // elapsed time, so the canvas has to be asked to redraw on the frames
        // the screen actually presents.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            Canvas(rendersAsynchronously: true) { canvas, size in
                let offset = geometry.scrollOffset(since: lastSampleAt, at: context.date,
                                                   interval: AudioMeterState.sampleInterval)
                let count = min(levels.count, geometry.barCount(forWidth: size.width))
                guard count > 0 else { return }
                // Bars run newest-first from the trailing edge, so the strip
                // fills the viewport rather than floating at half its width,
                // and the drawn span stays centred on the viewport's own 50%.
                for index in 0..<count {
                    let level = levels[levels.count - 1 - index]
                    let height = max(minimumHeight, CGFloat(level) * amplitude)
                    let rect = CGRect(x: geometry.x(forIndexFromNewest: index,
                                                    width: size.width, offset: offset),
                                      y: (size.height - height) / 2,
                                      width: geometry.barWidth, height: height)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: geometry.barWidth / 2),
                                with: .color(.primary.opacity(isLive ? 0.72 : 0.32)))
                }
            }
        }
        .mask(Self.edgeFade)
    }

    /// Hides bars entering and leaving the viewport. It is wider than one pitch,
    /// which is also what covers the gap a stalled meter opens at the trailing edge.
    private static var edgeFade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0),
                               .init(color: .black, location: 0.06),
                               .init(color: .black, location: 0.94),
                               .init(color: .clear, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
    }
}
