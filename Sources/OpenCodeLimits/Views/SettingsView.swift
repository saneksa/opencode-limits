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
        let window = NSWindow(contentViewController: controller)
        window.title = "Настройки — OpenCode Go"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 480, height: 640))
        window.minSize = NSSize(width: 440, height: 420)
        window.maxSize = NSSize(width: 760, height: 1100)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Transient view-local state. An ObservableObject box is used instead of
/// `@State` because the latter requires a compiler macro plugin that is absent
/// from some CommandLineTools SDK installations.
final class SettingsLocalState: ObservableObject {
    @Published var manualKey = ""
    @Published var connectionMessage: String?
    @Published var isTesting = false
}

/// Preferences window. Never prints or logs the API key.
struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var state: AppState
    @StateObject private var local = SettingsLocalState()

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
        ScrollView {
            Form {
                Section("Обновление") {
                    Picker("Интервал опроса", selection: $settings.pollInterval) {
                        Text("30 сек").tag(30.0)
                        Text("1 мин").tag(60.0)
                        Text("5 мин").tag(300.0)
                    }
                    Picker("В строке меню", selection: $settings.trayMeterRaw) {
                        ForEach(TrayMeter.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    Text("Влияет только на иконку в строке меню. В окне и в уведомлениях всегда видны все три лимита.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Кольцо отката 5 ч", isOn: $settings.trayCountdown)
                    Text("Внутреннее кольцо показывает, сколько осталось до сброса 5-часового окна. Оно всегда относится к 5-часовому лимиту, даже если выбран Месяц.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Stepper(value: $settings.warnThreshold, in: 0...100, step: 5) {
                        Text("Предупреждать при \(settings.warnThreshold)%")
                    }
                }

                Section("Энергосбережение") {
                    Toggle("Уменьшать опрос от батареи", isOn: $settings.powerSavingEnabled)
                    Picker("Интервал от батареи", selection: $settings.batteryPollInterval) {
                        Text("1 мин").tag(60.0)
                        Text("5 мин").tag(300.0)
                        Text("15 мин").tag(900.0)
                    }
                    Text(powerCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Low Power Mode и работа от батареи также реже обновляют кольцо и историю активности. Во сне таймеры приложения приостанавливаются.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Ключ доступа Go") {
                    Picker("Источник", selection: $settings.keySourceRaw) {
                        ForEach(KeySource.allCases) { source in
                            Text(source.rawValue).tag(source.rawValue)
                        }
                    }
                    Text("Активный источник: \(state.credentialStore.activeSourceDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("Новый ключ", text: $local.manualKey)
                    HStack {
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

                Section("Соединение") {
                    Button("Проверить соединение") {
                        testConnection()
                    }
                    .disabled(local.isTesting)
                    if let message = local.connectionMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Запуск") {
                    Toggle("Запускать при входе в систему", isOn: $settings.launchAtLogin)
                    if let error = settings.launchAtLoginError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Конфиденциальность") {
                    Text("ключ не логируется, БД только для чтения, содержимое переписки не читается")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 440, minHeight: 560)
    }

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
