import Carbon
import Foundation

@MainActor
final class HotKeyManager {
    private enum HotKeyID {
        static let general: UInt32 = 1
        static let coding: UInt32 = 2
    }

    private var generalHotKey: EventHotKeyRef?
    private var codingHotKey: EventHotKeyRef?
    private var generalConfiguration: HotKeyConfiguration?
    private var codingConfiguration: HotKeyConfiguration?
    private var eventHandler: EventHandlerRef?
    private var callback: ((CaptureMode) -> Void)?
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
            guard status == noErr, id.signature == manager.signature,
                  let mode = manager.mode(for: id.id) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { manager.fireOnce(mode) }
            return noErr
        }, 1, &spec, pointer, &eventHandler)
    }

    private let signature: OSType = 0x444B5445 // DKTE

    /// Registers both configurable shortcuts. A General registration failure is
    /// fatal; a Coding registration failure leaves General active and any previous
    /// Coding registration intact, and is reported as `false` to the caller.
    @discardableResult
    func register(general: HotKeyConfiguration, coding: HotKeyConfiguration,
                  callback: @escaping (CaptureMode) -> Void) throws -> Bool {
        let oldGeneral = generalHotKey
        let oldCoding = codingHotKey

        let replacingGeneral = generalConfiguration != general || generalHotKey == nil
        let generalCandidate: EventHotKeyRef
        if replacingGeneral {
            generalCandidate = try register(general, id: HotKeyID.general)
        } else {
            guard let generalHotKey else { throw DikteError.hotKeyConflict }
            generalCandidate = generalHotKey
        }

        let replacingCoding = codingConfiguration != coding || codingHotKey == nil
        var codingCandidate: EventHotKeyRef?
        if replacingCoding {
            do {
                codingCandidate = try register(coding, id: HotKeyID.coding)
            } catch {
                // Keep the newly registered General shortcut. If an older Coding
                // shortcut existed, its registration is left intact.
                if replacingGeneral {
                    if let oldGeneral { UnregisterEventHotKey(oldGeneral) }
                    generalHotKey = generalCandidate
                    generalConfiguration = general
                }
                self.callback = callback
                return false
            }
        } else {
            codingCandidate = codingHotKey
        }

        if replacingGeneral, let oldGeneral { UnregisterEventHotKey(oldGeneral) }
        if replacingCoding, let oldCoding { UnregisterEventHotKey(oldCoding) }
        generalHotKey = generalCandidate
        generalConfiguration = general
        codingHotKey = codingCandidate
        codingConfiguration = coding
        self.callback = callback
        return true
    }

    func unregister() {
        if let generalHotKey { UnregisterEventHotKey(generalHotKey) }
        if let codingHotKey { UnregisterEventHotKey(codingHotKey) }
        generalHotKey = nil
        codingHotKey = nil
        generalConfiguration = nil
        codingConfiguration = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    private func register(_ configuration: HotKeyConfiguration, id: UInt32) throws -> EventHotKeyRef {
        var candidate: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(configuration.keyCode, configuration.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, let candidate else { throw DikteError.hotKeyConflict }
        return candidate
    }

    private func mode(for id: UInt32) -> CaptureMode? {
        switch id {
        case HotKeyID.general: .general
        case HotKeyID.coding: .coding
        default: nil
        }
    }

    private func fireOnce(_ mode: CaptureMode) {
        guard !isHandling else { return }
        isHandling = true
        callback?(mode)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            isHandling = false
        }
    }
}
