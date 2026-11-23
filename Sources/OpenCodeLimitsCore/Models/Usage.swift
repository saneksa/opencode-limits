import Foundation

// MARK: - Meter status

/// Status of a single usage window as reported by the OpenCode Go API.
/// Unknown raw values are decoded as `.unknown` instead of throwing so that a
/// newly introduced server-side status can never break the menu bar app.
public enum MeterStatus: String, Codable, Sendable {
    case ok
    case rateLimited = "rate-limited"
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = MeterStatus(rawValue: raw) ?? .unknown
    }
}

// MARK: - Meter

/// One usage window (rolling, weekly or monthly).
public struct UsageMeter: Codable, Sendable, Equatable {
    public let status: MeterStatus
    public let percent: Int
    public let resetsAt: Date?

    public var isRateLimited: Bool { status == .rateLimited }

    /// A meter is critical when it is rate-limited or reached the warning
    /// threshold (user-configurable, defaults to 80%).
    public var isCritical: Bool {
        if isRateLimited { return true }
        return percent >= Self.configuredWarnThreshold
    }

    public var timeUntilReset: TimeInterval? { resetsAt?.timeIntervalSinceNow }

    private enum CodingKeys: String, CodingKey {
        case status, percent, resetsAt
    }

    public init(status: MeterStatus, percent: Int, resetsAt: Date?) {
        self.status = status
        self.percent = min(100, max(0, percent))
        self.resetsAt = resetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.status = (try? container.decode(MeterStatus.self, forKey: .status)) ?? .unknown
        let rawPercent = (try? container.decode(Int.self, forKey: .percent)) ?? 0
        self.percent = min(100, max(0, rawPercent))
        if let raw = try? container.decode(String.self, forKey: .resetsAt) {
            self.resetsAt = UsageMeter.parseISO8601(raw)
        } else {
            self.resetsAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(percent, forKey: .percent)
        if let resetsAt {
            try container.encode(UsageMeter.formatISO8601(resetsAt), forKey: .resetsAt)
        } else {
            try container.encodeNil(forKey: .resetsAt)
        }
    }

    /// Neutral meter used when a payload omits one of the windows.
    public static let unknown = UsageMeter(status: .unknown, percent: 0, resetsAt: nil)

    private static var configuredWarnThreshold: Int {
        let value = UserDefaults.standard.object(forKey: AppDefaultsKey.warnThreshold)
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        return AppConfig.defaultWarnThreshold
    }

    private static let fractionalParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses ISO-8601 timestamps with or without fractional seconds and with
    /// a `Z` (UTC) suffix or numeric timezone offset.
    public static func parseISO8601(_ value: String) -> Date? {
        if let date = fractionalParser.date(from: value) { return date }
        if let date = plainParser.date(from: value) { return date }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(secondsFromGMT: 0)
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return fallback.date(from: value)
    }

    public static func formatISO8601(_ date: Date) -> String {
        fractionalParser.string(from: date)
    }
}

// MARK: - Row

/// A single row of the menu-bar usage list.
public struct MeterRow: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let meter: UsageMeter

    public init(id: String, title: String, meter: UsageMeter) {
        self.id = id
        self.title = title
        self.meter = meter
    }
}

// MARK: - Snapshot

/// All three usage windows plus the time they were fetched.
public struct UsageSnapshot: Codable, Sendable, Equatable {
    public let rolling: UsageMeter
    public let weekly: UsageMeter
    public let monthly: UsageMeter
    public let fetchedAt: Date

    private enum CodingKeys: String, CodingKey {
        case usage, rolling, weekly, monthly, fetchedAt
    }

    private enum MeterKeys: String, CodingKey {
        case rolling, weekly, monthly
    }

    public init(rolling: UsageMeter, weekly: UsageMeter, monthly: UsageMeter, fetchedAt: Date = Date()) {
        self.rolling = rolling
        self.weekly = weekly
        self.monthly = monthly
        self.fetchedAt = fetchedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rolling: UsageMeter
        let weekly: UsageMeter
        let monthly: UsageMeter
        if let nested = try? container.nestedContainer(keyedBy: MeterKeys.self, forKey: .usage) {
            rolling = (try? nested.decode(UsageMeter.self, forKey: .rolling)) ?? .unknown
            weekly = (try? nested.decode(UsageMeter.self, forKey: .weekly)) ?? .unknown
            monthly = (try? nested.decode(UsageMeter.self, forKey: .monthly)) ?? .unknown
        } else {
            rolling = (try? container.decode(UsageMeter.self, forKey: .rolling)) ?? .unknown
            weekly = (try? container.decode(UsageMeter.self, forKey: .weekly)) ?? .unknown
            monthly = (try? container.decode(UsageMeter.self, forKey: .monthly)) ?? .unknown
        }
        self.rolling = rolling
        self.weekly = weekly
        self.monthly = monthly

        if let raw = try? container.decode(String.self, forKey: .fetchedAt) {
            self.fetchedAt = UsageMeter.parseISO8601(raw) ?? Date()
        } else if let interval = try? container.decode(Double.self, forKey: .fetchedAt) {
            self.fetchedAt = Date(timeIntervalSinceReferenceDate: interval)
        } else {
            self.fetchedAt = Date()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var nested = container.nestedContainer(keyedBy: MeterKeys.self, forKey: .usage)
        try nested.encode(rolling, forKey: .rolling)
        try nested.encode(weekly, forKey: .weekly)
        try nested.encode(monthly, forKey: .monthly)
        try container.encode(UsageMeter.formatISO8601(fetchedAt), forKey: .fetchedAt)
    }

    /// The most concerning window: rate-limited first, then highest percent.
    public var worst: UsageMeter {
        let all = [rolling, weekly, monthly]
        return all.max { lhs, rhs in
            let lhsRank = lhs.isRateLimited ? 1 : 0
            let rhsRank = rhs.isRateLimited ? 1 : 0
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.percent < rhs.percent
        } ?? .unknown
    }

    /// Row models for the menu-bar list, in stable display order.
    public var meters: [MeterRow] {
        [
            MeterRow(id: "rolling", title: "5 часов", meter: rolling),
            MeterRow(id: "weekly", title: "Неделя", meter: weekly),
            MeterRow(id: "monthly", title: "Месяц", meter: monthly),
        ]
    }

    public static let empty = UsageSnapshot(
        rolling: .unknown,
        weekly: .unknown,
        monthly: .unknown,
        fetchedAt: Date(timeIntervalSince1970: 0)
    )
}

// MARK: - Errors

public enum UsageError: Error, LocalizedError, Sendable {
    case missingKey
    case invalidKey
    case noSubscription(String)
    case network(String)
    case decoding(String)
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Ключ API OpenCode Go не найден. Укажите ключ в настройках или в переменной OPENCODE_GO_KEY."
        case .invalidKey:
            return "Недействительный ключ API OpenCode Go (401)."
        case .noSubscription(let message):
            return "Подписка OpenCode Go отсутствует или не активна: \(message)"
        case .network(let detail):
            return "Ошибка сети: \(detail)"
        case .decoding(let detail):
            return "Не удалось разобрать ответ сервера: \(detail)"
        case .database(let detail):
            return "Ошибка базы данных: \(detail)"
        }
    }
}

// MARK: - Shared constants

/// Where the Go API key can come from. Raw values are used as identifiers and
/// never contain the key itself.
public enum KeySource: String, CaseIterable, Identifiable, Sendable {
    case database = "opencode.db"
    case keychain = "Keychain"
    case environment = "OPENCODE_GO_KEY"

    public var id: String { rawValue }

    /// Human-readable Russian name (safe to display, contains no secret).
    public var title: String {
        switch self {
        case .database: return "База данных OpenCode"
        case .keychain: return "Keychain"
        case .environment: return "Переменная окружения"
        }
    }
}

public enum AppDefaultsKey {
    public static let powerSaving = "powerSaving"
    public static let batteryPollInterval = "batteryPollInterval"
    public static let trayMeter = "trayMeter"
    public static let activityPeriod = "activityPeriod"
    public static let pollInterval = "pollInterval"
    public static let warnThreshold = "warnThreshold"
    public static let keySource = "keySource"
    public static let launchAtLogin = "launchAtLogin"
    public static let activityMetric = "activityMetric"
}

/// Which usage window drives the menu-bar icon. The popup always shows all
/// three meters; this selection only affects the icon.
public enum TrayMeter: String, CaseIterable, Identifiable, Sendable {
    case rolling = "rolling"
    case weekly = "weekly"
    case monthly = "monthly"
    case auto = "auto"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rolling: return "5 часов"
        case .weekly: return "Неделя"
        case .monthly: return "Месяц"
        case .auto: return "Авто (максимум)"
        }
    }

    public static let `default`: TrayMeter = .rolling
}

public extension UsageSnapshot {
    /// Returns the meter selected for the menu-bar icon.
    /// `.auto` keeps the old behaviour (`worst` = max percent, rate-limited first).
    func meter(for selection: TrayMeter) -> UsageMeter {
        switch selection {
        case .rolling: return rolling
        case .weekly: return weekly
        case .monthly: return monthly
        case .auto: return worst
        }
    }
}

public extension UsageMeter {
    /// Fraction of the 5-hour rolling window still left: 1 = a full 5 hours
    /// remain, 0 = the reset is due now. `nil` when no reset time is known.
    /// Values outside 0...1 are clamped, so a server timestamp slightly in the
    /// future/past can never produce an invalid arc.
    func rollingWindowFraction(now: Date = Date()) -> Double? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return min(1, max(0, remaining / AppConfig.rollingWindowDuration))
    }
}

public enum AppConfig {
    public static let rollingWindowDuration: TimeInterval = 5 * 3_600
    public static let defaultPollInterval: TimeInterval = 60
    public static let defaultBatteryPollInterval: TimeInterval = 300
    public static let normalClockInterval: TimeInterval = 30
    public static let energySavingClockInterval: TimeInterval = 60
    public static let normalActivityInterval: TimeInterval = 5 * 60
    public static let energySavingActivityInterval: TimeInterval = 15 * 60

    /// Pure, testable interval resolution. When energy saving is enabled and the
    /// machine is on battery / Low Power Mode, the poll interval becomes at least
    /// `battery` (never shorter than the normal `base`). Otherwise `base` is used.
    public static func effectivePollInterval(
        base: TimeInterval,
        battery: TimeInterval,
        state: PowerState,
        enabled: Bool
    ) -> TimeInterval {
        enabled && state.isEnergySaving ? max(base, battery) : base
    }

    public static let defaultWarnThreshold: Int = 80
    public static let usageEndpoint: URL = URL(string: "https://opencode.ai/inference/go/v1/usage")!
    public static let userAgent = "opencode-limits-monitor/0.1"

    public static let defaultDatabasePath: String =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
}
