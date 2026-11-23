import SwiftUI
import AppKit
import OpenCodeLimitsCore

/// Creates the single shared AppState, owns the status item and pauses work
/// while the Mac sleeps. The accessory policy keeps the app out of the Dock
/// even when launched from SwiftPM during development.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        StatusBarController.shared.start(state: state)

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.state.suspendForSleep() }
            }
        )
        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.state.resumeFromWake() }
            }
        )

        if ProcessInfo.processInfo.environment["OPENCODE_SHOW_SETTINGS_ON_LAUNCH"] == "1" {
            SettingsWindowController.shared.show(state: state)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct OpenCodeLimitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Qualified because the app defines its own `Settings` class.
        SwiftUI.Settings {
            SettingsView()
                .environmentObject(appDelegate.state)
                .environmentObject(appDelegate.state.settings)
        }
    }
}
