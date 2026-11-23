import Foundation

/// Reads activity from the OpenCode Desktop V2 service running on localhost.
/// Unlike the Go API client, this service must never go through the system
/// proxy. Any failure is propagated to `ActivityService`, which falls back to
/// the read-only database. No password, header or key is ever logged.
public final class LocalAPIService: @unchecked Sendable {
    private static let defaultPasswordPath = NSHomeDirectory() + "/.config/opencode/service.json"
    private static let defaultCLIRoot = NSHomeDirectory()
        + "/Library/Application Support/ai.opencode.desktop/cli"

    private let passwordPath: String
    private let cliPath: String?
    private let session: URLSession
    private let lock = NSLock()
    private var cachedBaseURL: String?

    public init(passwordPath: String? = nil, cliPath: String? = nil, session: URLSession? = nil) {
        self.passwordPath = passwordPath
            ?? ProcessInfo.processInfo.environment["OPENCODE_SERVICE_CONFIG"]
            ?? LocalAPIService.defaultPasswordPath
        self.cliPath = cliPath
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // Localhost traffic must bypass the HTTPS proxy used for opencode.ai.
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 10
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Discovers and caches `http://127.0.0.1:<port>` from
    /// `<opencode-cli> service status`. Stale cached ports are invalidated when
    /// a request fails, so a restarted desktop service is picked up on retry.
    public func baseURL() throws -> String {
        lock.lock()
        let cached = cachedBaseURL
        lock.unlock()
        if let cached { return cached }

        let executable = try resolveCLIPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["service", "status"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw UsageError.network("Не удалось запустить локальный CLI OpenCode")
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
            throw UsageError.network("Локальный CLI OpenCode не ответил вовремя")
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let pattern = #"http://127\.0\.0\.1:\d+"#
        guard let match = output.range(of: pattern, options: .regularExpression) else {
            throw UsageError.network("Не удалось определить адрес локального сервиса OpenCode")
        }
        let url = String(output[match])
        lock.lock()
        cachedBaseURL = url
        lock.unlock()
        return url
    }

    public func invalidateBaseURL() {
        lock.lock()
        cachedBaseURL = nil
        lock.unlock()
    }

    public func fetch(days: Int) async throws -> ActivitySnapshot {
        do {
            return try await fetchOnce(days: days)
        } catch {
            // The desktop service may have restarted on a different port.
            invalidateBaseURL()
            return try await fetchOnce(days: days)
        }
    }

    // MARK: - Discovery / auth

    private func resolveCLIPath() throws -> String {
        let manager = FileManager.default
        if let explicit = cliPath {
            guard manager.isExecutableFile(atPath: explicit) else {
                throw UsageError.network("Указанный CLI OpenCode недоступен")
            }
            return explicit
        }
        guard let entries = try? manager.contentsOfDirectory(atPath: LocalAPIService.defaultCLIRoot) else {
            throw UsageError.network("Каталог CLI OpenCode не найден")
        }
        let candidates = entries.compactMap { entry -> String? in
            let path = (LocalAPIService.defaultCLIRoot as NSString)
                .appendingPathComponent(entry + "/opencode-cli")
            return manager.isExecutableFile(atPath: path) ? path : nil
        }
        guard let newest = candidates.sorted().last else {
            throw UsageError.network("Исполняемый файл opencode-cli не найден")
        }
        return newest
    }

    private func authorizationHeader() throws -> String {
        guard let data = FileManager.default.contents(atPath: passwordPath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let password = json["password"] as? String, !password.isEmpty else {
            throw UsageError.network("Не удалось прочитать пароль локального сервиса OpenCode")
        }
        // The "opencode:" username prefix is mandatory for Basic auth here.
        let token = Data(("opencode:" + password).utf8).base64EncodedString()
        return "Basic " + token
    }

    // MARK: - Requests

    private func fetchOnce(days: Int) async throws -> ActivitySnapshot {
        let effectiveDays = max(1, days)
        let now = Date()
        let fromMs = Int64(now.addingTimeInterval(-Double(effectiveDays) * 86_400).timeIntervalSince1970 * 1_000)
        let toMs = Int64(now.timeIntervalSince1970 * 1_000)
        let base = try baseURL()
        let auth = try authorizationHeader()

        var statsComponents = URLComponents(string: base)
        statsComponents?.path = "/api/experimental/session/stats"
        statsComponents?.queryItems = [
            URLQueryItem(name: "from", value: String(fromMs)),
            URLQueryItem(name: "to", value: String(toMs)),
            URLQueryItem(name: "tools", value: "none"),
            URLQueryItem(name: "timezone", value: TimeZone.current.identifier),
        ]
        guard let statsURL = statsComponents?.url else {
            throw UsageError.network("Некорректный адрес статистики OpenCode")
        }
        let statsData = try await requestData(statsURL, auth: auth)
        let stats = try JSONDecoder().decode(Envelope<Stats>.self, from: statsData).data

        var sessionComponents = URLComponents(string: base)
        sessionComponents?.path = "/api/session"
        guard let sessionsURL = sessionComponents?.url else {
            throw UsageError.network("Некорректный адрес сессий OpenCode")
        }
        let sessionsData = try await requestData(sessionsURL, auth: auth)
        let sessions = try JSONDecoder().decode(Envelope<[APISession]>.self, from: sessionsData).data

        return assemble(stats: stats, sessions: sessions, days: effectiveDays, now: now)
    }

    private func requestData(_ url: URL, auth: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UsageError.network("HTTP \(code)")
        }
        return data
    }

    // MARK: - Assembly

    private static let localDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = .current
        formatter.timeZone = .current
        return formatter
    }()

    private func assemble(
        stats: Stats,
        sessions: [APISession],
        days: Int,
        now: Date
    ) -> ActivitySnapshot {
        // `/api/session` returns the whole history, while `stats` covers only
        // the requested window. Keep only sessions active inside that window,
        // otherwise a 7-day view would list sessions from months ago.
        let cutoffMs = (now.timeIntervalSince1970 - Double(days) * 86_400) * 1_000
        let relevant = sessions.filter { $0.activityMs >= cutoffMs }
        let events = relevant.map { session in
            UsageEvent(
                id: session.id.isEmpty ? UUID().uuidString : session.id,
                date: Date(timeIntervalSince1970: session.activityMs / 1_000),
                tokens: session.tokens.breakdown,
                cost: session.cost,
                providerID: session.model.providerID,
                modelID: session.model.id,
                sessionID: session.id,
                sessionTitle: session.title,
                projectName: session.projectID
            )
        }
        let base = ActivityService.aggregate(events: events, days: days, now: now, source: .api)

        var stepsByDay: [Date: Int] = [:]
        let calendar = Calendar.current
        for day in stats.activity {
            guard let parsed = LocalAPIService.localDateFormatter.date(from: day.date) else { continue }
            let start = calendar.startOfDay(for: parsed)
            stepsByDay[start, default: 0] += day.steps
        }

        var daily = base.daily
        for index in daily.indices {
            daily[index].messages = stepsByDay[daily[index].start] ?? 0
        }
        var monthly = base.monthly
        for index in monthly.indices {
            let start = monthly[index].start
            let end = monthly[index].end
            monthly[index].messages = stepsByDay.reduce(0) { total, entry in
                entry.key >= start && entry.key < end ? total + entry.value : total
            }
        }

        let models = stats.models.map { entry -> ModelBucket in
            var bucket = ModelBucket(
                id: "\(entry.model.providerID)|\(entry.model.id)",
                providerID: entry.model.providerID,
                modelID: entry.model.id
            )
            bucket.tokens = entry.tokens.total
            bucket.cost = entry.cost
            bucket.messages = entry.steps
            return bucket
        }.sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.messages > $1.messages }

        return ActivitySnapshot(
            events: base.events,
            daily: daily,
            hourly: [],
            monthly: monthly,
            models: models,
            sessions: base.sessions,
            totalTokens: stats.tokens.total,
            totalCost: stats.cost,
            totalMessages: stats.steps,
            generatedAt: now,
            source: .api
        )
    }

    // MARK: - Wire models

    private struct Envelope<T: Decodable>: Decodable {
        let data: T
    }

    private struct CacheCounts: Decodable {
        let read: Int
        let write: Int

        init() {
            read = 0
            write = 0
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            read = (try? container.decode(Int.self, forKey: .read)) ?? 0
            write = (try? container.decode(Int.self, forKey: .write)) ?? 0
        }

        private enum CodingKeys: String, CodingKey { case read, write }
    }

    private struct TokenCounts: Decodable {
        let input: Int
        let output: Int
        let reasoning: Int
        let cache: CacheCounts

        var total: Int { input + output + reasoning + cache.read + cache.write }

        var breakdown: TokenBreakdown {
            TokenBreakdown(
                input: input,
                output: output,
                reasoning: reasoning,
                cacheRead: cache.read,
                cacheWrite: cache.write
            )
        }

        init() {
            input = 0
            output = 0
            reasoning = 0
            cache = CacheCounts()
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            input = (try? container.decode(Int.self, forKey: .input)) ?? 0
            output = (try? container.decode(Int.self, forKey: .output)) ?? 0
            reasoning = (try? container.decode(Int.self, forKey: .reasoning)) ?? 0
            cache = (try? container.decode(CacheCounts.self, forKey: .cache)) ?? CacheCounts()
        }

        private enum CodingKeys: String, CodingKey { case input, output, reasoning, cache }
    }

    private struct ModelInfo: Decodable {
        let id: String
        let providerID: String
        let variant: String?

        init() {
            id = ""
            providerID = ""
            variant = nil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decode(String.self, forKey: .id)) ?? ""
            providerID = (try? container.decode(String.self, forKey: .providerID)) ?? ""
            variant = try? container.decode(String.self, forKey: .variant)
        }

        private enum CodingKeys: String, CodingKey { case id, providerID, variant }
    }

    private struct DayActivity: Decodable {
        let date: String
        let steps: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = (try? container.decode(String.self, forKey: .date)) ?? ""
            steps = (try? container.decode(Int.self, forKey: .steps)) ?? 0
        }

        private enum CodingKeys: String, CodingKey { case date, steps }
    }

    private struct ModelStat: Decodable {
        let model: ModelInfo
        let steps: Int
        let tokens: TokenCounts
        let cost: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = (try? container.decode(ModelInfo.self, forKey: .model)) ?? ModelInfo()
            steps = (try? container.decode(Int.self, forKey: .steps)) ?? 0
            tokens = (try? container.decode(TokenCounts.self, forKey: .tokens)) ?? TokenCounts()
            cost = (try? container.decode(Double.self, forKey: .cost)) ?? 0
        }

        private enum CodingKeys: String, CodingKey { case model, steps, tokens, cost }
    }

    private struct Stats: Decodable {
        let steps: Int
        let cost: Double
        let tokens: TokenCounts
        let activity: [DayActivity]
        let models: [ModelStat]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            steps = (try? container.decode(Int.self, forKey: .steps)) ?? 0
            cost = (try? container.decode(Double.self, forKey: .cost)) ?? 0
            tokens = (try? container.decode(TokenCounts.self, forKey: .tokens)) ?? TokenCounts()
            activity = (try? container.decode([DayActivity].self, forKey: .activity)) ?? []
            models = (try? container.decode([ModelStat].self, forKey: .models)) ?? []
        }

        private enum CodingKeys: String, CodingKey { case steps, cost, tokens, activity, models }
    }

    private struct APISession: Decodable {
        let id: String
        let projectID: String
        let title: String
        let model: ModelInfo
        let cost: Double
        let tokens: TokenCounts
        let createdMs: Double
        /// Last activity in the session (`time.updated`), falling back to its
        /// creation time. This is the timestamp used for period filtering and
        /// for placing the session's tokens on the chart.
        let activityMs: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decode(String.self, forKey: .id)) ?? ""
            projectID = (try? container.decode(String.self, forKey: .projectID)) ?? ""
            title = (try? container.decode(String.self, forKey: .title)) ?? ""
            model = (try? container.decode(ModelInfo.self, forKey: .model)) ?? ModelInfo()
            cost = (try? container.decode(Double.self, forKey: .cost)) ?? 0
            tokens = (try? container.decode(TokenCounts.self, forKey: .tokens)) ?? TokenCounts()
            var created = Date().timeIntervalSince1970 * 1_000
            var updated = created
            if let time = try? container.nestedContainer(keyedBy: TimeKeys.self, forKey: .time) {
                created = (try? time.decode(Double.self, forKey: .created)) ?? created
                updated = (try? time.decode(Double.self, forKey: .updated)) ?? created
            }
            createdMs = created
            activityMs = max(created, updated)
        }

        private enum CodingKeys: String, CodingKey {
            case id, projectID, title, model, cost, tokens, time
        }

        private enum TimeKeys: String, CodingKey { case created, updated }
    }
}
