import Foundation
import Combine
import ServiceManagement
import OpenCodeLimitsCore

/// User-configurable preferences backed by UserDefaults.
///
/// Every change is persisted immediately. Launch-at-login is best-effort:
/// `SMAppService` only works for a real bundled .app, so failures are surfaced
/// as an inline message instead of crashing a developer (SwiftPM) build.
final class Settings: ObservableObject {
    @Published var pollInterval: TimeInterval {
        didSet { defaults.set(pollInterval, forKey: AppDefaultsKey.pollInterval) }
    }
    @Published var warnThreshold: Int {
        didSet { defaults.set(warnThreshold, forKey: AppDefaultsKey.warnThreshold) }
    }
    @Published var keySourceRaw: String {
        didSet { defaults.set(keySourceRaw, forKey: AppDefaultsKey.keySource) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: AppDefaultsKey.launchAtLogin)
            applyLaunchAtLogin()
        }
    }
    @Published var activityMetric: String {
        didSet { defaults.set(activityMetric, forKey: AppDefaultsKey.activityMetric) }
    }
    /// 7 / 30 / 90 days, or 0 for the entire loaded history.
    @Published var activityPeriod: Int {
        didSet { defaults.set(activityPeriod, forKey: AppDefaultsKey.activityPeriod) }
    }
    /// Which meter drives the menu-bar icon; `.auto` uses the worst meter.
    @Published var trayMeterRaw: String {
        didSet { defaults.set(trayMeterRaw, forKey: AppDefaultsKey.trayMeter) }
    }
    /// Slow the poll/icon/activity cadence on battery or in Low Power Mode.
    @Published var powerSavingEnabled: Bool {
        didSet { defaults.set(powerSavingEnabled, forKey: AppDefaultsKey.powerSaving) }
    }
    @Published var batteryPollInterval: TimeInterval {
        didSet { defaults.set(batteryPollInterval, forKey: AppDefaultsKey.batteryPollInterval) }
    }
    @Published var launchAtLoginError: String?

    var trayMeter: TrayMeter {
        TrayMeter(rawValue: trayMeterRaw) ?? .rolling
    }

    func effectivePollInterval(for state: PowerState) -> TimeInterval {
        AppConfig.effectivePollInterval(
            base: pollInterval,
            battery: batteryPollInterval,
            state: state,
            enabled: powerSavingEnabled
        )
    }

    private let defaults: UserDefaults

    private static let allowedIntervals: [TimeInterval] = [30, 60, 300]
    private static let allowedActivityPeriods = [7, 30, 90, 0]
    private static let allowedBatteryIntervals: [TimeInterval] = [60, 300, 900]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedInterval = defaults.object(forKey: AppDefaultsKey.pollInterval) as? TimeInterval
        self.pollInterval = Self.allowedIntervals.first(where: { $0 == storedInterval })
            ?? AppConfig.defaultPollInterval

        let storedThreshold = defaults.object(forKey: AppDefaultsKey.warnThreshold) as? Int
        self.warnThreshold = storedThreshold.map { min(100, max(0, $0)) }
            ?? AppConfig.defaultWarnThreshold

        let storedSource = defaults.string(forKey: AppDefaultsKey.keySource) ?? KeySource.database.rawValue
        self.keySourceRaw = KeySource.allCases.contains(where: { $0.rawValue == storedSource })
            ? storedSource
            : KeySource.database.rawValue

        self.launchAtLogin = defaults.bool(forKey: AppDefaultsKey.launchAtLogin)

        let storedMetric = defaults.string(forKey: AppDefaultsKey.activityMetric) ?? "tokens"
        self.activityMetric = storedMetric == "cost" ? "cost" : "tokens"

        let storedPeriod = defaults.object(forKey: AppDefaultsKey.activityPeriod) as? Int
        self.activityPeriod = storedPeriod.map { Self.allowedActivityPeriods.contains($0) ? $0 : 30 } ?? 30

        let storedTrayMeter = defaults.string(forKey: AppDefaultsKey.trayMeter) ?? TrayMeter.rolling.rawValue
        self.trayMeterRaw = TrayMeter.allCases.contains(where: { $0.rawValue == storedTrayMeter })
            ? storedTrayMeter
            : TrayMeter.rolling.rawValue

        self.powerSavingEnabled = (defaults.object(forKey: AppDefaultsKey.powerSaving) as? Bool) ?? true
        let storedBatteryInterval = defaults.object(forKey: AppDefaultsKey.batteryPollInterval) as? TimeInterval
        self.batteryPollInterval = Self.allowedBatteryIntervals.first(where: { $0 == storedBatteryInterval })
            ?? AppConfig.defaultBatteryPollInterval
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Не удалось изменить автозапуск: \(error.localizedDescription). Запуск при входе требует настоящего .app-бандла."
        }
    }
}
