import Foundation
import UserNotifications
import AppKit
import OpenCodeLimitsCore

/// Fires a single local notification per meter per billing window.
///
/// All mutable tracking is confined to the main actor: `AppState` calls
/// `evaluate` from `MainActor.run`, and the authorization callback is hopped
/// onto the main queue. The `@unchecked Sendable` conformance therefore only
/// documents that the class may cross actor boundaries as a reference.
final class Notifier: @unchecked Sendable {
    private var didRequestAuthorization = false
    private var authorized = false
    private var lastNotifiedPercent: [String: Int] = [:]
    private var lastNotifiedReset: [String: Date?] = [:]
    private var notifiedThisWindow: [String: Bool] = [:]

    func requestAuthorization() {
        guard !didRequestAuthorization else { return }
        // `swift run` / `make run` launches a bare binary with no .app bundle;
        // UNUserNotificationCenter.current() aborts there with
        // "bundleProxyForCurrentProcess is nil". Skip the request in that case —
        // `deliver` then falls back to NSSound.beep().
        guard Bundle.main.bundleIdentifier != nil else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.authorized = granted }
        }
    }

    /// Emits at most one alert per meter per window: either when the configured
    /// threshold is crossed or when the meter becomes rate-limited. A changed
    /// `resetsAt` marks a fresh window and re-arms the meter.
    func evaluate(_ snapshot: UsageSnapshot, threshold: Int) {
        for row in snapshot.meters {
            let id = row.id
            let meter = row.meter

            let previousReset = lastNotifiedReset[id]
            let resetChanged: Bool
            switch (previousReset, meter.resetsAt) {
            case let (old?, new?): resetChanged = old != new
            case (nil, nil):       resetChanged = false
            default:               resetChanged = true
            }

            if resetChanged {
                notifiedThisWindow[id] = false
                lastNotifiedPercent[id] = nil
            }
            lastNotifiedReset[id] = meter.resetsAt

            if notifiedThisWindow[id] == true { continue }

            let isRateLimited = meter.isRateLimited
            let crossedThreshold = meter.percent >= threshold && (lastNotifiedPercent[id] ?? 0) < threshold

            if isRateLimited || crossedThreshold {
                notifiedThisWindow[id] = true
                lastNotifiedPercent[id] = meter.percent

                let body: String
                if isRateLimited {
                    body = "\(row.title): лимит исчерпан."
                } else {
                    body = "\(row.title): использовано \(meter.percent)% (порог \(threshold)%)."
                }
                deliver(title: "OpenCode Go — достигнут лимит", body: body)
            } else if lastNotifiedPercent[id] == nil {
                // Remember the baseline without notifying.
                lastNotifiedPercent[id] = meter.percent
            }
        }
    }

    private func deliver(title: String, body: String) {
        guard authorized else {
            NSSound.beep()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
