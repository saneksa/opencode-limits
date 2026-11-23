import AppKit
import Combine
import SwiftUI
import OpenCodeLimitsCore

/// Owns the menu-bar status item. An AppKit status item is used instead of
/// SwiftUI's MenuBarExtra so left and right clicks can be told apart.
@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var state: AppState?
    private var cancellables = Set<AnyCancellable>()

    func start(state: AppState) {
        guard statusItem == nil else { return }
        self.state = state

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        item.button?.image = iconImage(for: state)
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(handleClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item
        self.popover = popover

        // Icon-only redraws: never trigger a refresh from these sinks.
        subscribeToIconChanges(state)
    }

    private func subscribeToIconChanges(_ state: AppState) {
        state.$clock
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateIcon() }
            }
            .store(in: &cancellables)
        state.$trayMeter
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateIcon() }
            }
            .store(in: &cancellables)
        state.$trayCountdownMeter
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateIcon() }
            }
            .store(in: &cancellables)
        state.$showTrayCountdown
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateIcon() }
            }
            .store(in: &cancellables)
    }

    private func iconImage(for state: AppState) -> NSImage {
        TrayIcon.image(
            for: state.trayMeter,
            countdown: state.trayCountdownMeter,
            now: state.clock,
            showCountdown: state.showTrayCountdown
        )
    }

    private func updateIcon() {
        guard let state else { return }
        statusItem?.button?.image = iconImage(for: state)
    }

    // MARK: - Clicks

    @objc
    private func handleClick(_ sender: NSStatusBarButton) {
        guard let state else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(state: state)
        } else {
            togglePopover(state: state)
        }
    }

    private func togglePopover(state: AppState) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(state: state)
        }
    }

    private func showPopover(state: AppState) {
        guard let popover, let button = statusItem?.button else { return }
        let rootView = MenuBarView()
            .environmentObject(state)
            .environmentObject(state.settings)
        popover.contentViewController = NSHostingController(rootView: rootView)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showContextMenu(state: AppState) {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Открыть", action: #selector(openFromMenu(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let settings = NSMenuItem(title: "Настройки…", action: #selector(openSettingsFromMenu(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Выход", action: #selector(quitFromMenu(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        // Pop up at the cursor. `statusItem.menu` is deliberately never set,
        // so left clicks keep opening the popover.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc
    private func openFromMenu(_ sender: NSMenuItem) {
        guard let state else { return }
        showPopover(state: state)
    }

    @objc
    private func openSettingsFromMenu(_ sender: NSMenuItem) {
        guard let state else { return }
        SettingsWindowController.shared.show(state: state)
    }

    @objc
    private func quitFromMenu(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
