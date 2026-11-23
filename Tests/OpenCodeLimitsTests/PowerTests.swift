import Foundation
import OpenCodeLimitsCore

// MARK: - Power-aware polling checks

enum PowerTests {
    static func run() {
        powerSaving()
    }

    private static func powerSaving() {
        // Pure pmset parsing.
        equal(PowerState.parse(pmsetOutput: "Now drawing from 'AC Power'", lowPowerEnabled: true),
              .lowPower, "Low Power Mode wins over AC")
        equal(PowerState.parse(pmsetOutput: "Now drawing from 'Battery Power'", lowPowerEnabled: false),
              .battery, "battery power detected")
        equal(PowerState.parse(pmsetOutput: "Now drawing from 'AC Power'", lowPowerEnabled: false),
              .ac, "AC power detected")
        equal(PowerState.parse(pmsetOutput: "unrecognised output", lowPowerEnabled: false),
              .unknown, "garbage output is unknown")
        equal(PowerState.parse(pmsetOutput: "bAtTeRy PoWeR", lowPowerEnabled: false),
              .battery, "pmset parsing is case-insensitive")

        // Titles and energy-saving classification.
        let allStates: [PowerState] = [.ac, .battery, .lowPower, .unknown]
        check(allStates.allSatisfy { !$0.title.isEmpty }, "all power state titles are non-empty")
        check(allStates.filter { $0.title.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF } }
                .count == 3, "Russian power state titles (lowPower keeps its official English name)")
        equal(PowerState.ac.isEnergySaving, false, "AC is not energy saving")
        equal(PowerState.battery.isEnergySaving, true, "battery is energy saving")
        equal(PowerState.lowPower.isEnergySaving, true, "Low Power Mode is energy saving")
        equal(PowerState.unknown.isEnergySaving, false, "unknown is not energy saving")

        // Interval resolution.
        equal(AppConfig.effectivePollInterval(base: 60, battery: 300, state: .battery, enabled: true),
              300, "energy saving on battery extends poll interval")
        equal(AppConfig.effectivePollInterval(base: 60, battery: 300, state: .lowPower, enabled: true),
              300, "energy saving in Low Power Mode extends poll interval")
        equal(AppConfig.effectivePollInterval(base: 60, battery: 300, state: .ac, enabled: true),
              60, "energy saving on AC keeps base interval")
        equal(AppConfig.effectivePollInterval(base: 60, battery: 300, state: .battery, enabled: false),
              60, "disabled energy saving keeps base interval")
        equal(AppConfig.effectivePollInterval(base: 600, battery: 300, state: .battery, enabled: true),
              600, "base longer than battery interval is kept")

        // Constants and defaults keys.
        equal(AppConfig.defaultBatteryPollInterval, 300, "default battery poll interval")
        equal(AppConfig.normalClockInterval, 30, "normal clock interval")
        equal(AppConfig.energySavingClockInterval, 60, "energy saving clock interval")
        equal(AppConfig.normalActivityInterval, 300, "normal activity interval")
        equal(AppConfig.energySavingActivityInterval, 900, "energy saving activity interval")
        equal(AppDefaultsKey.powerSaving, "powerSaving", "powerSaving defaults key")
        equal(AppDefaultsKey.batteryPollInterval, "batteryPollInterval", "batteryPollInterval defaults key")

        // Live detector must not crash; its value is intentionally not printed.
        let state = PowerMonitor().current()
        check([PowerState.ac, .battery, .lowPower, .unknown].contains(state),
              "PowerMonitor returns a valid state")
    }
}
