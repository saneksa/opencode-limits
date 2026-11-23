import SwiftUI
import AppKit
import OpenCodeLimitsCore

/// Opens the preferences window. `@Environment(\.openSettings)` is macOS 14+,
/// so an AppKit-hosted window is used to keep macOS 13 support.
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    @MainActor
    func show(state: AppState) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = SettingsView()
            .environmentObject(state)
            .environmentObject(state.settings)
        let controller = NSHostingController(rootView: rootView)
        controller.preferredContentSize = NSSize(width: 600, height: 700)

        // Create the window explicitly: NSWindow(contentViewController:) adopts
        // the hosting controller's fitting size, which is wider than the screen
        // layout and clips long labels.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки — OpenCode Go"
        window.contentViewController = controller
        window.minSize = NSSize(width: 520, height: 460)
        window.maxSize = NSSize(width: 900, height: 1100)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Transient view-local state. An ObservableObject box is used instead of the
/// SwiftUI State property wrapper because its compiler macro plugin is absent
/// from some CommandLineTools SDK installations.
final class SettingsLocalState: ObservableObject {
    @Published var manualKey = ""
    @Published var connectionMessage: String?
    @Published var isTesting = false
    /// Visual tab selection only; not persisted as a settings key.
    @Published var tab = 0
}

/// Preferences window. Never prints or logs the API key.
struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var state: AppState
    @StateObject private var local = SettingsLocalState()

    private let labelColumnWidth: CGFloat = 170

    /// The normal poll interval can be 30 s, so a plain `/60` would render
    /// "раз в 0 мин". Show seconds below a minute.
    private var powerCaption: String {
        let interval = state.effectivePollInterval
        let label = interval < 60
            ? "\(Int(interval)) сек"
            : "\(Int(interval / 60)) мин"
        return "Питание: \(state.powerState.title) • опрос раз в \(label)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $local.tab) {
                Text("Общие").tag(0)
                Text("Подключение").tag(1)
                Text("Энергосбережение").tag(2)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    if local.tab == 0 {
                        generalTab
                    } else if local.tab == 1 {
                        connectionTab
                    } else {
                        energyTab
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Persistent privacy footer, outside the scroll view.
            Text("Ключ не логируется · БД только для чтения · содержимое переписки не читается")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tabs

    @ViewBuilder
    private var generalTab: some View {
        settingRow("Интервал опроса") {
            Picker("", selection: $settings.pollInterval) {
                Text("30 сек").tag(30.0)
                Text("1 мин").tag(60.0)
                Text("5 мин").tag(300.0)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        settingRow("В строке меню") {
            Picker("", selection: $settings.trayMeterRaw) {
                ForEach(TrayMeter.allCases) { item in
                    Text(item.title).tag(item.rawValue)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        fullWidthCaption("Кольцо показывает время до сброса 5-часового окна, цифра — выбранный лимит. В окне и в уведомлениях всегда видны все три лимита.")

        settingRow("Предупреждать при \(settings.warnThreshold)%") {
            Stepper("", value: $settings.warnThreshold, in: 0...100, step: 5)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        Divider()

        settingRow("Запускать при входе в систему") {
            Toggle("", isOn: $settings.launchAtLogin)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let error = settings.launchAtLoginError {
            fullWidthCaption(error, color: .orange)
        }
    }

    @ViewBuilder
    private var connectionTab: some View {
        settingRow("Источник") {
            Picker("", selection: $settings.keySourceRaw) {
                ForEach(KeySource.allCases) { source in
                    Text(source.rawValue).tag(source.rawValue)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        fullWidthCaption("Активный источник: \(state.credentialStore.activeSourceDescription)")

        settingRow("Новый ключ") {
            SecureField("", text: $local.manualKey)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        fullWidthRow {
            HStack(spacing: 12) {
                Button("Сохранить в Keychain") {
                    saveKey()
                }
                .disabled(local.manualKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Удалить") {
                    state.credentialStore.clearManualKey()
                    local.manualKey = ""
                    local.connectionMessage = "Сохранённый ключ удалён."
                }
            }
        }

        Divider()

        fullWidthRow {
            Button("Проверить соединение") {
                testConnection()
            }
            .disabled(local.isTesting)
        }
        if let message = local.connectionMessage {
            fullWidthCaption(message)
        }
    }

    @ViewBuilder
    private var energyTab: some View {
        settingRow("Уменьшать опрос от батареи") {
            Toggle("", isOn: $settings.powerSavingEnabled)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        settingRow("Интервал от батареи") {
            Picker("", selection: $settings.batteryPollInterval) {
                Text("1 мин").tag(60.0)
                Text("5 мин").tag(300.0)
                Text("15 мин").tag(900.0)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        fullWidthCaption(powerCaption)
        fullWidthCaption("В Low Power Mode и при работе от батареи приложение реже опрашивает API, перерисовывает иконку и загружает активность. Во сне таймеры приостанавливаются.")
    }

    // MARK: - Layout helpers

    private func settingRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.body)
                .frame(width: labelColumnWidth, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fullWidthRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Spacer(minLength: 0).frame(width: labelColumnWidth)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fullWidthCaption(_ text: String, color: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Spacer(minLength: 0).frame(width: labelColumnWidth)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func saveKey() {
        let key = local.manualKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try state.credentialStore.saveManualKey(key)
            local.manualKey = ""
            local.connectionMessage = "Ключ сохранён в Keychain."
            state.refresh(requestActivity: false)
        } catch {
            local.connectionMessage = "Не удалось сохранить ключ: \(error.localizedDescription)"
        }
    }

    private func testConnection() {
        local.isTesting = true
        local.connectionMessage = "Проверка соединения…"
        let store = state.credentialStore
        Task { @MainActor in
            let service = GoUsageService { try store.goAPIKey() }
            do {
                let snapshot = try await service.fetch()
                self.local.connectionMessage = "OK: rolling \(snapshot.rolling.percent)%, weekly \(snapshot.weekly.percent)%, monthly \(snapshot.monthly.percent)%."
            } catch {
                self.local.connectionMessage = "Ошибка: \(error.localizedDescription)"
            }
            self.local.isTesting = false
        }
    }
}
