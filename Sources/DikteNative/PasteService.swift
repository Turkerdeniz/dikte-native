import AppKit
import ApplicationServices
import UserNotifications

@MainActor
final class PasteService {
    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func copyAndOptionallyPaste(_ text: String, shouldPaste: Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        guard shouldPaste else { return true }
        guard accessibilityGranted else { notify("Metin panoya kopyalandı", "Otomatik yapıştırma için Erişilebilirlik izni gerekli."); return false }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
