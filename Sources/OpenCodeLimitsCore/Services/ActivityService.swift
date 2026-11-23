import Foundation
import Dispatch

/// Loads assistant-message activity from the OpenCode database read-only.
/// Only token counts, model/session metadata and timestamps are selected:
/// the `data.content` field (private prompts) is never read, and the legacy
/// `part` table is never touched because it duplicates `session_message`.
public final class ActivityService: @unchecked Sendable {
    private let storedDatabasePath: String
    private let apiService: LocalAPIService

    /// The API service is injectable so callers and tests can force the
    /// SQLite fallback (e.g. by supplying an invalid CLI path).
    public init(dbPath: String? = nil, apiService: LocalAPIService? = nil) {
        self.storedDatabasePath = dbPath
            ?? ProcessInfo.processInfo.environment["OPENCODE_DB_PATH"]
            ?? AppConfig.defaultDatabasePath
        self.apiService = apiService ?? LocalAPIService()
    }

    public var databasePath: String { storedDatabasePath }

    private static let query = """
        SELECT
          sm.id,
          sm.session_id,
          sm.time_created,
          json_extract(sm.data, '$.tokens.input'),
          json_extract(sm.data, '$.tokens.output'),
          json_extract(sm.data, '$.tokens.reasoning'),
          json_extract(sm.data, '$.tokens.cache.read'),
          json_extract(sm.data, '$.tokens.cache.write'),
          COALESCE(json_extract(sm.data, '$.cost'), 0),
          json_extract(sm.data, '$.model.providerID'),
          json_extract(sm.data, '$.model.id'),
          COALESCE(sv2.title, ''),
          COALESCE(p.name, '')
        FROM session_message AS sm
        LEFT JOIN session_v2 AS sv2 ON sv2.id = sm.session_id
        LEFT JOIN project AS p ON p.id = sv2.project_id
        WHERE sm.type = 'assistant' AND sm.time_created >= ?
        ORDER BY sm.time_created ASC
        """

    /// API-first: tries the running OpenCode Desktop V2 service and silently
    /// falls back to the read-only database on any failure (missing CLI,
    /// missing password, non-200, timeout, decode error). The returned
    /// `source` tells the UI which path produced the data.
    public func load(days: Int = 30) throws -> ActivitySnapshot {
        let effectiveDays = max(1, days)
        // The public API is synchronous, while LocalAPIService.fetch is async.
        // Use a detached task so a caller on the main actor cannot deadlock the
        // bridge, and always fall through to the database on any failure.
        let box = FetchBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .utility) {
            let result: Result<ActivitySnapshot, Error>
            do {
                result = .success(try await self.apiService.fetch(days: effectiveDays))
            } catch {
                result = .failure(error)
            }
            box.store(result)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            return try loadFromDatabase(days: effectiveDays)
        }
        switch box.take() {
        case .success(let snapshot)?:
            return snapshot
        case .failure, nil:
            return try loadFromDatabase(days: effectiveDays)
        }
    }

    private final class FetchBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<ActivitySnapshot, Error>?

        func store(_ value: Result<ActivitySnapshot, Error>) {
            lock.lock()
            result = value
            lock.unlock()
        }

        func take() -> Result<ActivitySnapshot, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    /// Loads all assistant messages since `now - days * 86400` with a single
    /// parameterized query. Totals, `hourly`, `monthly`, `models` and `sessions`
    /// always cover the full loaded range. `daily` is deliberately capped at
    /// the most recent 90 days: even `load(days: 3650)` allocates at most 90
    /// daily buckets while still aggregating every loaded event into the
    /// other collections.
    private func loadFromDatabase(days: Int) throws -> ActivitySnapshot {
        let effectiveDays = max(1, days)
        guard FileManager.default.fileExists(atPath: storedDatabasePath) else {
            return .empty
        }

        let events: [UsageEvent]
        do {
            let database = try SQLiteDatabase(path: storedDatabasePath)
            defer { database.close() }
            let statement = try database.prepare(Self.query)
            defer { statement.finalize() }

            let cutoffMs = Int64(
                Date().addingTimeInterval(-Double(effectiveDays) * 86_400).timeIntervalSince1970 * 1_000
            )
            try statement.bind(cutoffMs, at: 1)

            var loaded: [UsageEvent] = []
            while try statement.step() {
                let sessionID = statement.string(at: 1) ?? ""
                let milliseconds = statement.int(at: 2)
                let identifier = statement.string(at: 0) ?? ""
                let tokens = TokenBreakdown(
                    input: Int(clamping: statement.int(at: 3)),
                    output: Int(clamping: statement.int(at: 4)),
                    reasoning: Int(clamping: statement.int(at: 5)),
                    cacheRead: Int(clamping: statement.int(at: 6)),
                    cacheWrite: Int(clamping: statement.int(at: 7))
                )
                loaded.append(
                    UsageEvent(
                        id: identifier.isEmpty ? "msg-\(sessionID)-\(milliseconds)-\(loaded.count)" : identifier,
                        date: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
                        tokens: tokens,
                        cost: statement.double(at: 8),
                        providerID: statement.string(at: 9) ?? "",
                        modelID: statement.string(at: 10) ?? "",
                        sessionID: sessionID,
                        sessionTitle: statement.string(at: 11) ?? "",
                        projectName: statement.string(at: 12) ?? ""
                    )
                )
            }
            events = loaded
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.database(error.localizedDescription)
        }

        guard !events.isEmpty else { return .empty }
        return Self.aggregate(events: events, days: effectiveDays)
    }

    // MARK: - Pure aggregation

    /// Aggregates events into all snapshot collections. Public so the UI can
    /// re-render instantly and tests can exercise aggregation without a DB.
    public static func aggregate(
        events: [UsageEvent],
        days: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current,
        source: ActivitySource = .database
    ) -> ActivitySnapshot {
        let effectiveDays = max(1, days)
        var seen = Set<String>()
        let unique = events.filter { event in
            if event.id.isEmpty { return true }
            return seen.insert(event.id).inserted
        }

        let daily = makeDailyBuckets(unique, days: effectiveDays, now: now, calendar: calendar)
        let hourly = makeHourlyBuckets(unique, now: now, calendar: calendar)
        let monthly = makeMonthlyBuckets(unique, calendar: calendar)
        let models = makeModelBuckets(unique)
        let sessions = makeSessionSummaries(unique)

        return ActivitySnapshot(
            events: unique,
            daily: daily,
            hourly: hourly,
            monthly: monthly,
            models: models,
            sessions: sessions,
            totalTokens: unique.reduce(0) { $0 + $1.tokens.total },
            totalCost: unique.reduce(0) { $0 + $1.cost },
            totalMessages: unique.count,
            generatedAt: now,
            source: source
        )
    }

    private static func makeDailyBuckets(
        _ events: [UsageEvent],
        days: Int,
        now: Date,
        calendar: Calendar
    ) -> [ActivityBucket] {
        let today = calendar.startOfDay(for: now)
        var buckets: [ActivityBucket] = []
        // Cap the chart data: totals and all other collections still use every
        // event, only the number of daily buckets is bounded.
        let bucketCount = min(max(1, days), 90)
        for offset in stride(from: bucketCount - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            buckets.append(ActivityBucket(start: start, end: end))
        }
        for index in buckets.indices {
            let start = buckets[index].start
            let end = buckets[index].end
            for event in events where event.date >= start && event.date < end {
                buckets[index].tokens += event.tokens.total
                buckets[index].cost += event.cost
                buckets[index].messages += 1
            }
        }
        return buckets
    }

    private static func makeHourlyBuckets(
        _ events: [UsageEvent],
        now: Date,
        calendar: Calendar
    ) -> [ActivityBucket] {
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        let currentHour = calendar.date(from: components) ?? now
        var buckets: [ActivityBucket] = []
        for offset in stride(from: 4, through: 0, by: -1) {
            let start = calendar.date(byAdding: .hour, value: -offset, to: currentHour)
                ?? currentHour.addingTimeInterval(-3_600 * Double(offset))
            let end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(3_600)
            buckets.append(ActivityBucket(start: start, end: end))
        }
        for index in buckets.indices {
            let start = buckets[index].start
            let end = buckets[index].end
            for event in events where event.date >= start && event.date < end {
                buckets[index].tokens += event.tokens.total
                buckets[index].cost += event.cost
                buckets[index].messages += 1
            }
        }
        return buckets
    }

    /// Monthly buckets for the whole event range, using local calendar month
    /// boundaries (`Calendar.current` by default via `aggregate`). Months with
    /// no events between the first and the last event are zero-filled; there
    /// is intentionally no cap on the number of buckets.
    private static func makeMonthlyBuckets(
        _ events: [UsageEvent],
        calendar: Calendar
    ) -> [ActivityBucket] {
        guard let first = events.map(\.date).min(),
              let last = events.map(\.date).max() else { return [] }
        let firstComponents = calendar.dateComponents([.year, .month], from: first)
        let lastComponents = calendar.dateComponents([.year, .month], from: last)
        guard var start = calendar.date(from: firstComponents),
              let finalMonthStart = calendar.date(from: lastComponents) else { return [] }

        var buckets: [ActivityBucket] = []
        while start <= finalMonthStart {
            guard let end = calendar.date(byAdding: .month, value: 1, to: start), end > start else { break }
            buckets.append(ActivityBucket(start: start, end: end))
            start = end
        }
        for index in buckets.indices {
            let start = buckets[index].start
            let end = buckets[index].end
            for event in events where event.date >= start && event.date < end {
                buckets[index].tokens += event.tokens.total
                buckets[index].cost += event.cost
                buckets[index].messages += 1
            }
        }
        return buckets
    }

    private static func makeModelBuckets(_ events: [UsageEvent]) -> [ModelBucket] {
        var grouped: [String: ModelBucket] = [:]
        for event in events {
            let key = "\(event.providerID)|\(event.modelID)"
            if var bucket = grouped[key] {
                bucket.tokens += event.tokens.total
                bucket.cost += event.cost
                bucket.messages += 1
                grouped[key] = bucket
            } else {
                var bucket = ModelBucket(
                    id: key,
                    providerID: event.providerID,
                    modelID: event.modelID
                )
                bucket.tokens = event.tokens.total
                bucket.cost = event.cost
                bucket.messages = 1
                grouped[key] = bucket
            }
        }
        return grouped.values.sorted { lhs, rhs in
            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            return lhs.messages > rhs.messages
        }
    }

    private static func makeSessionSummaries(_ events: [UsageEvent]) -> [SessionSummary] {
        var grouped: [String: SessionSummary] = [:]
        for event in events {
            let title = event.sessionTitle.isEmpty ? "Без названия" : event.sessionTitle
            let project = event.projectName.isEmpty ? "Без проекта" : event.projectName
            let model = event.modelID.isEmpty ? "Неизвестно" : event.modelID
            if let summary = grouped[event.sessionID] {
                let isNewer = event.date >= summary.lastActive
                grouped[event.sessionID] = SessionSummary(
                    id: summary.id,
                    title: isNewer ? title : summary.title,
                    project: isNewer ? project : summary.project,
                    model: isNewer ? model : summary.model,
                    tokens: summary.tokens + event.tokens.total,
                    cost: summary.cost + event.cost,
                    messages: summary.messages + 1,
                    lastActive: isNewer ? event.date : summary.lastActive
                )
            } else {
                grouped[event.sessionID] = SessionSummary(
                    id: event.sessionID,
                    title: title,
                    project: project,
                    model: model,
                    tokens: event.tokens.total,
                    cost: event.cost,
                    messages: 1,
                    lastActive: event.date
                )
            }
        }
        return Array(grouped.values.sorted { $0.lastActive > $1.lastActive }.prefix(12))
    }
}
