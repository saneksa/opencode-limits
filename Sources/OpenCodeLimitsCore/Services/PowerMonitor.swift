import Foundation

/// Detects the current power state using Low Power Mode and `pmset -g batt`.
/// Results are cached for a minute so frequent icon redraws do not spawn
/// processes. No output or private information is logged.
public final class PowerMonitor: @unchecked Sendable {
    public static let shared = PowerMonitor()

    private static let cacheDuration: TimeInterval = 60
    private let lock = NSLock()
    private var cachedState: PowerState?
    private var cachedAt: Date?

    public init() {}

    public func current() -> PowerState {
        let lowPowerEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        lock.lock()
        if let state = cachedState, let at = cachedAt,
           Date().timeIntervalSince(at) < Self.cacheDuration {
            lock.unlock()
            return state
        }
        lock.unlock()

        let state = readState(lowPowerEnabled: lowPowerEnabled)
        lock.lock()
        cachedState = state
        cachedAt = Date()
        lock.unlock()
        return state
    }

    private func readState(lowPowerEnabled: Bool) -> PowerState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return fallback(lowPowerEnabled)
        }

        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            return fallback(lowPowerEnabled)
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let parsed = PowerState.parse(pmsetOutput: output, lowPowerEnabled: lowPowerEnabled)
        return parsed == .unknown ? fallback(lowPowerEnabled) : parsed
    }

    private func fallback(_ lowPowerEnabled: Bool) -> PowerState {
        lowPowerEnabled ? .lowPower : .unknown
    }
}
