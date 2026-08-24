import Carbon
import Foundation

@MainActor
final class HotKeyManager {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var callback: (() -> Void)?
    private var isHandling = false

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == manager.signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { manager.fireOnce() }
            return noErr
        }, 1, &spec, pointer, &eventHandler)
    }

    private let signature: OSType = 0x444B5445 // DKTE

    func register(_ configuration: HotKeyConfiguration, callback: @escaping () -> Void) throws {
        var candidate: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(configuration.keyCode, configuration.modifiers, id, GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, let candidate else { throw DikteError.hotKeyConflict }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate
        self.callback = callback
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    private func fireOnce() {
        guard !isHandling else { return }
        isHandling = true
        callback?()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            isHandling = false
        }
    }
}
