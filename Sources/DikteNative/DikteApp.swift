import AppKit
import Darwin
import ServiceManagement
import SwiftUI

enum MaintenanceCommand: Equatable {
    case unregisterLoginItem

    static func parse(arguments: [String]) -> MaintenanceCommand? {
        arguments.contains("--maintenance-unregister-login-item") ? .unregisterLoginItem : nil
    }
}

@main
struct DikteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            DikteMenu(model: model)
        } label: {
            MenuBarIcon(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("Dikte Settings", id: "settings") {
            SettingsView(model: model).onAppear { delegate.model = model }
        }
        .windowResizability(.contentSize)
    }
}

private struct DikteMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(model.isCapturing ? "Stop Recording" : "Start Recording") { model.toggleRecording() }.disabled(model.isProcessing)
        Button("Cancel") { model.cancel() }.disabled(!model.isProcessing)
        Divider()
        Button("Copy Last Result") { model.copyLastResult() }.disabled(model.lastResult == nil)
        Button("New Codex Conversation") { model.resetCodexConversation() }
        Divider()
        Button("Settings…") { showSettings() }
        Button("Quit") { model.shutdown(); NSApplication.shared.terminate(nil) }
    }
    private func showSettings() { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
}

private struct MenuBarIcon: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: iconName)
            .onReceive(NotificationCenter.default.publisher(for: .dikteOpenSettings)) { _ in
                openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true)
            }
    }

    private var iconName: String {
        switch model.phase {
        case .idle: "waveform.circle"
        case .arming: "mic.badge.plus"
        case .recording: "waveform.circle.fill"
        case .processing(.transcribing): "text.bubble"
        case .processing(.retryingTranscription): "arrow.clockwise.circle"
        case .processing(.askingCodex): "sparkles"
        case .processing: "ellipsis.circle"
        }
    }
}

extension Notification.Name { static let dikteOpenSettings = Notification.Name("DikteOpenSettings") }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let command = MaintenanceCommand.parse(arguments: CommandLine.arguments) {
            runMaintenance(command)
        }
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { NotificationCenter.default.post(name: .dikteOpenSettings, object: nil) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .dikteOpenSettings, object: nil); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.shutdown(); return .terminateNow
    }

    private func runMaintenance(_ command: MaintenanceCommand) -> Never {
        NSApp.setActivationPolicy(.prohibited)
        do {
            switch command {
            case .unregisterLoginItem:
                switch SMAppService.mainApp.status {
                case .enabled, .requiresApproval:
                    try SMAppService.mainApp.unregister()
                case .notRegistered, .notFound:
                    break
                @unknown default:
                    try SMAppService.mainApp.unregister()
                }
                writeMaintenanceMessage("Dikte login item kaydı kaldırıldı.\n", to: .standardOutput)
            }
            exit(EXIT_SUCCESS)
        } catch {
            writeMaintenanceMessage("Dikte bakım işlemi başarısız: \(error.localizedDescription)\n",
                                    to: .standardError)
            exit(EXIT_FAILURE)
        }
    }

    private func writeMaintenanceMessage(_ message: String, to handle: FileHandle) {
        if let data = message.data(using: .utf8) { try? handle.write(contentsOf: data) }
    }
}
