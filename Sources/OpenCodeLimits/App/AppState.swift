import Foundation
import Combine
import SwiftUI
import OpenCodeLimitsCore

/// Single source of truth for the menu-bar UI. All published state is mutated
/// on the main actor; network and database work runs in a detached task and is
/// published back through `MainActor.run`.
@MainActor
final class AppState: ObservableObject {
    @Published var usage: UsageSnapshot?
    @Published var activity: ActivitySnapshot?
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    /// The meter currently drawn in the menu bar, selected by the user.
    @Published var trayMeter: UsageMeter?
    /// Always the rolling meter, independent of `trayMeter`; drives the reset arc.
    @Published var trayCountdownMeter: UsageMeter?
    /// Ticks every 30 s so the reset arc advances between network polls.
    @Published var clock = Date()
    @Published var powerState: PowerState = .unknown
    @Published var effectivePollInterval: TimeInterval = AppConfig.defaultPollInterval

    let notifier = Notifier()
    let settings: Settings
    let credentialStore: CredentialStore

    private let usageService: GoUsageService
    private let activityService: ActivityService

    private var refreshTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var clockTimer: Timer?
    private var lastActivityLoadDate: Date?
    private var cancellables = Set<AnyCancellable>()

    /// immutable hand-off from the detached task to the main actor
    private struct RefreshOutcome: Sendable {
        let usage: UsageSnapshot?
        let usageErrorMessage: String?
        let activity: ActivitySnapshot?
        let activityErrorMessage: String?
    }

    init(settings: Settings? = nil) {
        let resolvedSettings = settings ?? Settings()
        self.settings = resolvedSettings
        let initialPowerState = PowerMonitor.shared.current()
        self.powerState = initialPowerState
        self.effectivePollInterval = resolvedSettings.effectivePollInterval(for: initialPowerState)

        let store = CredentialStore()
        self.credentialStore = store
        self.usageService = GoUsageService { try store.goAPIKey() }
        self.activityService = ActivityService()
        store.preferredSource = KeySource(rawValue: resolvedSettings.keySourceRaw) ?? .database

        resolvedSettings.$pollInterval
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconfigureTimers() }
            }
            .store(in: &cancellables)

        resolvedSettings.$powerSavingEnabled
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconfigureTimers() }
            }
            .store(in: &cancellables)

        resolvedSettings.$batteryPollInterval
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconfigureTimers() }
            }
            .store(in: &cancellables)

        $powerState
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconfigureTimers() }
            }
            .store(in: &cancellables)

        resolvedSettings.$keySourceRaw
            .removeDuplicates()
            .sink { [weak self] raw in
                Task { @MainActor [weak self] in
                    self?.credentialStore.preferredSource = KeySource(rawValue: raw) ?? .database
                }
            }
            .store(in: &cancellables)

        resolvedSettings.$activityPeriod
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    // Explicit request bypasses the five-minute throttle.
                    self?.refresh(requestActivity: true)
                }
            }
            .store(in: &cancellables)

        resolvedSettings.$trayMeterRaw
            .removeDuplicates()
            .sink { [weak self] _ in
                // Icon-only change: never wait for (or trigger) a network poll.
                Task { @MainActor [weak self] in self?.updateTrayMeter() }
            }
            .store(in: &cancellables)

        notifier.requestAuthorization()
        scheduleTimer()
        scheduleClockTimer()
        // First launch uses the persisted period (activity == nil forces a load).
        refresh()
    }

    /// Called when the popover opens. Usage is refreshed every time; the
    /// (heavier) activity load stays throttled.
    func refreshOnOpen() {
        refresh()
    }

    /// Fetches usage and, at most every five minutes (or when requested),
    /// reloads the local activity database. Concurrent runs are coalesced.
    func refresh(requestActivity: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true

        let usageService = self.usageService
        let activityService = self.activityService
        let notifier = self.notifier
        let threshold = settings.warnThreshold
        // Resolved on the main actor; Int is Sendable and safe to capture.
        let days = settings.activityPeriod == 0 ? 3650 : settings.activityPeriod
        let loadActivity = requestActivity || activity == nil || isActivityStale

        refreshTask = Task.detached(priority: .userInitiated) { [weak self, days] in
            defer {
                // Guarantees the spinner stops even when the task is cancelled.
                Task { @MainActor [weak self] in self?.isRefreshing = false }
            }

            var newUsage: UsageSnapshot?
            var usageError: Error?
            do {
                newUsage = try await usageService.fetch()
            } catch {
                usageError = error
            }
            if Task.isCancelled { return }

            var newActivity: ActivitySnapshot?
            var activityError: Error?
            if loadActivity {
                do {
                    newActivity = try activityService.load(days: days)
                } catch {
                    activityError = error
                }
            }
            if Task.isCancelled { return }

            let outcome = RefreshOutcome(
                usage: newUsage,
                usageErrorMessage: usageError?.localizedDescription,
                activity: newActivity,
                activityErrorMessage: activityError?.localizedDescription
            )

            await MainActor.run { [weak self, outcome] in
                guard let self else { return }

                if let usage = outcome.usage {
                    self.usage = usage
                    self.updateTrayMeter()
                    self.lastUpdated = Date()
                    self.errorMessage = nil
                    notifier.evaluate(usage, threshold: threshold)
                } else if let message = outcome.usageErrorMessage {
                    // Keep the last successful snapshot on screen.
                    self.errorMessage = message
                    self.trayCountdownMeter = nil
                }

                if let activity = outcome.activity {
                    self.activity = activity
                    self.lastActivityLoadDate = Date()
                } else if let message = outcome.activityErrorMessage, self.errorMessage == nil {
                    self.errorMessage = message
                }

                self.isRefreshing = false
            }
        }
    }

    /// Re-selects the icon meter from the latest snapshot and setting, and
    /// keeps the rolling meter for the reset arc.
    private func updateTrayMeter() {
        guard let usage else {
            trayMeter = nil
            trayCountdownMeter = nil
            return
        }
        trayMeter = usage.meter(for: settings.trayMeter)
        trayCountdownMeter = usage.rolling
    }

    // MARK: - Power-aware scheduling

    private var isEnergySaving: Bool {
        settings.powerSavingEnabled && powerState.isEnergySaving
    }

    private var clockTickInterval: TimeInterval {
        isEnergySaving ? AppConfig.energySavingClockInterval : AppConfig.normalClockInterval
    }

    private var activityRefreshInterval: TimeInterval {
        isEnergySaving ? AppConfig.energySavingActivityInterval : AppConfig.normalActivityInterval
    }

    /// Re-reads the (internally cached) power state and lets the `$powerState`
    /// sink reschedule timers only when the value actually changed.
    private func refreshPowerState() {
        let current = PowerMonitor.shared.current()
        if current != powerState {
            powerState = current
        }
    }

    private func reconfigureTimers() {
        effectivePollInterval = settings.effectivePollInterval(for: powerState)
        scheduleTimer()
        scheduleClockTimer()
    }

    /// Pause all periodic work and the in-flight request while the Mac sleeps.
    func suspendForSleep() {
        pollTimer?.invalidate()
        pollTimer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func resumeFromWake() {
        powerState = PowerMonitor.shared.current()
        reconfigureTimers()
        refresh(requestActivity: true)
    }

    private var isActivityStale: Bool {
        guard let last = lastActivityLoadDate else { return true }
        return Date().timeIntervalSince(last) >= activityRefreshInterval
    }

    private func scheduleTimer() {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: effectivePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Purely visual tick: no network request and no `refresh()` call.
    private func scheduleClockTimer() {
        clockTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: clockTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clock = Date()
                self?.refreshPowerState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }
}
