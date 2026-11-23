import Foundation
import OpenCodeLimitsCore

// MARK: - Local V2 API checks (dependency-free, URLProtocol mock)

enum LocalAPITests {
    private static let expectedPassword = "test-password"

    private final class MockBox: @unchecked Sendable {
        static let shared = MockBox()
        private let lock = NSLock()
        private var stats = Data()
        private var sessions = Data()
        private var authorization: String?
        private var paths: [String] = []

        func configure(stats: Data, sessions: Data) {
            lock.lock()
            defer { lock.unlock() }
            self.stats = stats
            self.sessions = sessions
            self.authorization = nil
            self.paths = []
        }

        func payload(for path: String) -> Data {
            lock.lock()
            defer { lock.unlock() }
            paths.append(path)
            return path.hasSuffix("/stats") ? stats : sessions
        }

        func record(authorization value: String?) {
            lock.lock()
            defer { lock.unlock() }
            if authorization == nil { authorization = value }
        }

        func recordedAuthorization() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return authorization
        }

        func requestedPaths() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }

    private final class LocalMockURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let box = MockBox.shared
            box.record(authorization: request.value(forHTTPHeaderField: "Authorization"))
            let path = request.url?.path ?? ""
            let payload = box.payload(for: path)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1:49374")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    static func run() async {
        sourceContract()
        await apiFetch()
        apiFailureFallsBackToDatabase()
    }

    private static func sourceContract() {
        equal(ActivitySource.api.rawValue, "api", "ActivitySource.api rawValue")
        equal(ActivitySource.database.rawValue, "database", "ActivitySource.database rawValue")
        check(!ActivitySource.api.title.isEmpty, "ActivitySource.api title non-empty")
        check(ActivitySource.database.title.unicodeScalars.contains {
            $0.value >= 0x0400 && $0.value <= 0x04FF
        }, "ActivitySource titles are Russian")
        equal(ActivitySnapshot.empty.source, .database, "empty snapshot source is database")
        equal(ActivityService.aggregate(events: [], days: 1).source, .database,
              "aggregate default source is database")
    }

    private static func scratchDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "opencode-limits-local-api-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private static func apiFetch() async {
        do {
            let directory = try scratchDirectory()
            let passwordPath = (directory as NSString).appendingPathComponent("service.json")
            try #"{"password":"\#(expectedPassword)"}"#.write(
                toFile: passwordPath, atomically: true, encoding: .utf8
            )
            let cliPath = (directory as NSString).appendingPathComponent("opencode-cli")
            try "#!/bin/sh\necho 'service status: http://127.0.0.1:49374'\n".write(
                toFile: cliPath, atomically: true, encoding: .utf8
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliPath)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = .current
            formatter.timeZone = .current
            let now = Date()
            let today = formatter.string(from: now)
            let yesterday = formatter.string(from: now.addingTimeInterval(-86_400))
            let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
            let yesterdayMs = Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970 * 1_000)

            let stats = """
            {"data":{"range":{"from":\(nowMs - 604_800_000),"to":\(nowMs)},"sessions":2,"subagents":0,"prompts":10,"steps":6,"tokens":{"input":1000,"output":200,"reasoning":10,"cache":{"read":50,"write":5}},"cost":1.25,"tools":{},"activeDays":2,"streak":1,"activity":[{"date":"\(yesterday)","steps":2},{"date":"\(today)","steps":4}],"models":[{"model":{"id":"big-pickle","providerID":"opencode","variant":"default"},"steps":4,"tokens":{"input":800,"output":160,"reasoning":8,"cache":{"read":40,"write":4}},"cost":1.0},{"model":{"id":"small","providerID":"opencode","variant":"default"},"steps":2,"tokens":{"input":200,"output":40,"reasoning":2,"cache":{"read":10,"write":1}},"cost":0.25}]}}
            """
            let sessions = """
            {"data":[{"id":"s1","projectID":"p1","title":"Сессия 1","model":{"id":"big-pickle","providerID":"opencode","variant":"default"},"cost":1.0,"tokens":{"input":800,"output":160,"reasoning":8,"cache":{"read":40,"write":4}},"time":{"created":\(nowMs),"updated":\(nowMs)}},{"id":"s2","projectID":"p2","title":"Сессия 2","model":{"id":"small","providerID":"opencode","variant":"default"},"cost":0.25,"tokens":{"input":200,"output":40,"reasoning":2,"cache":{"read":10,"write":1}},"time":{"created":\(yesterdayMs),"updated":\(yesterdayMs)}}]}
            """
            MockBox.shared.configure(
                stats: Data(stats.utf8),
                sessions: Data(sessions.utf8)
            )

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LocalMockURLProtocol.self]
            let service = LocalAPIService(
                passwordPath: passwordPath,
                cliPath: cliPath,
                session: URLSession(configuration: configuration)
            )
            let snapshot = try await service.fetch(days: 7)

            equal(snapshot.source, .api, "local API snapshot source")
            equal(snapshot.totalTokens, 1_265, "stats token total")
            near(snapshot.totalCost, 1.25, accuracy: 0.0001, "stats cost total")
            equal(snapshot.totalMessages, 6, "stats steps total")
            equal(snapshot.events.count, 2, "synthetic events from /api/session")
            equal(snapshot.sessions.count, 2, "session summaries from /api/session")
            equal(snapshot.models.count, 2, "model buckets from stats")
            equal(snapshot.models.first?.modelID, "big-pickle", "top model from stats")
            equal(snapshot.models.first?.tokens, 1_012, "top model tokens from stats")
            equal(snapshot.models.first?.messages, 4, "top model steps from stats")
            check(snapshot.models[0].tokens >= snapshot.models[1].tokens, "models sorted by tokens")

            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: now)
            let yesterdayStart = calendar.startOfDay(for: now.addingTimeInterval(-86_400))
            let todayBucket = snapshot.daily.first { $0.start == todayStart }
            let yesterdayBucket = snapshot.daily.first { $0.start == yesterdayStart }
            check(todayBucket != nil, "daily bucket for today exists")
            equal(todayBucket?.messages, 4, "daily messages from stats (today)")
            equal(yesterdayBucket?.messages, 2, "daily messages from stats (yesterday)")
            check((todayBucket?.tokens ?? 0) > 0, "daily tokens from synthetic events")
            check((todayBucket?.cost ?? 0) > 0, "daily cost from synthetic events")
            check(!snapshot.monthly.isEmpty, "monthly buckets populated")
            let currentMonthBucket = snapshot.monthly.first {
                $0.start <= todayStart && todayStart < $0.end
            }
            check(currentMonthBucket != nil, "monthly bucket for current month exists")
            check((currentMonthBucket?.messages ?? 0) >= 4, "monthly messages from stats")

            let expectedAuth = "Basic " + Data(("opencode:" + expectedPassword).utf8).base64EncodedString()
            // Never print the header value, only whether it matches.
            check(MockBox.shared.recordedAuthorization() == expectedAuth, "Basic auth uses opencode: prefix")
            let paths = MockBox.shared.requestedPaths()
            check(paths.contains { $0.hasSuffix("/api/experimental/session/stats") }, "stats endpoint requested")
            check(paths.contains { $0 == "/api/session" }, "session endpoint requested")
        } catch {
            fail("local API fetch", "threw \(error)")
        }
    }

    private static func apiFailureFallsBackToDatabase() {
        do {
            let broken = LocalAPIService(cliPath: "/nonexistent/opencode-cli")
            let snapshot = try ActivityService(apiService: broken).load(days: 7)
            equal(snapshot.source, .database, "API failure falls back to database source")
        } catch {
            fail("API fallback", "threw \(error)")
        }
    }
}
