import AppKit
import Foundation
import OpenCodeLimitsCore

/// Owns the single shared AppState, the status item and the sleep/wake hooks.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    private var workspaceObservers: [NSObjectProtocol] = []

    /// Explicit bootstrap. SwiftUI's `App` lifecycle is intentionally not used:
    /// with `MenuBarExtra` replaced by an AppKit `NSStatusItem`, a lone
    /// `SwiftUI.Settings` scene is opened automatically on first launch. Also,
    /// `applicationDidFinishLaunching` is not delivered reliably with a pure
    /// AppKit `@main` delegate, so `Main.main()` calls this directly instead.
    func bootstrap() {
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

        // Debug hook: opens settings without a click. Never fires without the
        // env var, so the app normally starts with NO visible window.
        if ProcessInfo.processInfo.environment["OPENCODE_SHOW_SETTINGS_ON_LAUNCH"] == "1" {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                SettingsWindowController.shared.show(state: self.state)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Retains the delegate: `NSApplication.delegate` is weak, and `app.run()`
/// never returns, so a local constant in `main()` would otherwise be the only
/// strong reference (which is sufficient, but keeping it explicit is safer).
@MainActor private var retainedDelegate: AppDelegate?

@main
enum Main {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        retainedDelegate = delegate
        delegate.bootstrap()
        app.run()
    }
}
