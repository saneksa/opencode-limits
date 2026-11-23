import Foundation
import Darwin
import OpenCodeLimitsCore

// MARK: - Dependency-free test harness
// This machine has CommandLineTools only (no Apple test framework installed),
// so the checks use tiny local helpers instead.

final class TestSupport: @unchecked Sendable {
    static let shared = TestSupport()
    private let lock = NSLock()
    private var passedCount = 0
    private var failedCount = 0

    func pass(_ name: String) {
        lock.lock()
        passedCount += 1
        lock.unlock()
        print("[PASS] \(name)")
    }

    func failure(_ name: String, _ detail: String) {
        lock.lock()
        failedCount += 1
        lock.unlock()
        print("[FAIL] \(name) — \(detail)")
    }

    func finish() -> Never {
        lock.lock()
        let passed = passedCount
        let failed = failedCount
        lock.unlock()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        TestSupport.shared.pass(name)
    } else {
        TestSupport.shared.failure(name, "condition was false")
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected {
        TestSupport.shared.pass(name)
    } else {
        TestSupport.shared.failure(name, "expected \(expected), got \(actual)")
    }
}

func near(_ actual: Double?, _ expected: Double, accuracy: Double, _ name: String) {
    guard let actual else {
        TestSupport.shared.failure(name, "expected \(expected) ±\(accuracy), got nil")
        return
    }
    if abs(actual - expected) <= accuracy {
        TestSupport.shared.pass(name)
    } else {
        TestSupport.shared.failure(name, "expected \(expected) ±\(accuracy), got \(actual)")
    }
}

func fail(_ name: String, _ detail: String = "") {
    TestSupport.shared.failure(name, detail.isEmpty ? "check failed" : detail)
}

// MARK: - Usage decoding / HTTP mapping checks

enum UsageDecodingTests {
    private static let livePayload = """
    {"usage":{"rolling":{"status":"ok","percent":8,"resetsAt":"2026-11-23T11:18:05.000Z"},"weekly":{"status":"ok","percent":3,"resetsAt":"2026-11-30T00:00:00.000Z"},"monthly":{"status":"ok","percent":49,"resetsAt":"2026-12-16T18:47:26.000Z"}}}
    """

    private struct APIResponse: Decodable {
        let usage: Meters
    }

    private struct Meters: Decodable {
        let rolling: UsageMeter
        let weekly: UsageMeter
        let monthly: UsageMeter
    }

    static func run() async {
        livePayloadDecoding()
        unknownStatusNeverThrows()
        percentIsClamped()
        rateLimitedAndWorstMeter()
        trayMeterSelection()
        rollingWindowFraction()
        await successThroughMockAndHeaders()
        await unauthorizedMapsToInvalidKey()
        await forbiddenMapsToNoSubscription()
        await serverErrorMapsToNetwork()
        await decodeFailureMapsToDecoding()
        await keyProviderErrorIsPropagated()
    }

    private static func livePayloadDecoding() {
        do {
            let decoded = try JSONDecoder().decode(APIResponse.self, from: Data(livePayload.utf8))
            equal(decoded.usage.rolling.percent, 8, "live payload rolling percent")
            equal(decoded.usage.weekly.percent, 3, "live payload weekly percent")
            equal(decoded.usage.monthly.percent, 49, "live payload monthly percent")
            equal(decoded.usage.rolling.status, .ok, "live payload rolling status")
            equal(decoded.usage.weekly.status, .ok, "live payload weekly status")
            equal(decoded.usage.monthly.status, .ok, "live payload monthly status")

            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expected = [
                parser.date(from: "2026-11-23T11:18:05.000Z"),
                parser.date(from: "2026-11-30T00:00:00.000Z"),
                parser.date(from: "2026-12-16T18:47:26.000Z"),
            ]
            let actual = [
                decoded.usage.rolling.resetsAt,
                decoded.usage.weekly.resetsAt,
                decoded.usage.monthly.resetsAt,
            ]
            let names = ["rolling resetsAt", "weekly resetsAt", "monthly resetsAt"]
            for index in 0..<3 {
                check(actual[index] != nil, "\(names[index]) present")
                near(actual[index]?.timeIntervalSince(expected[index]!), 0, accuracy: 1, names[index])
            }
        } catch {
            fail("live payload decoding", "threw \(error)")
        }
    }

    private static func unknownStatusNeverThrows() {
        let json = #"{"status":"brand-new","percent":12,"resetsAt":null}"#
        do {
            let meter = try JSONDecoder().decode(UsageMeter.self, from: Data(json.utf8))
            equal(meter.status, .unknown, "unknown status → .unknown")
            check(!meter.isRateLimited, "unknown status is not rate-limited")
            check(meter.resetsAt == nil, "unknown status has no reset date")
            equal(meter.percent, 12, "unknown status keeps percent")
        } catch {
            fail("unknown status decoding", "threw \(error)")
        }
    }

    private static func percentIsClamped() {
        do {
            let high = try JSONDecoder().decode(UsageMeter.self, from: Data(#"{"status":"ok","percent":150}"#.utf8))
            let low = try JSONDecoder().decode(UsageMeter.self, from: Data(#"{"status":"ok","percent":-7}"#.utf8))
            equal(high.percent, 100, "percent 150 clamped to 100")
            equal(low.percent, 0, "percent -7 clamped to 0")
            equal(UsageMeter(status: .ok, percent: 999, resetsAt: nil).percent, 100, "init clamps percent")
        } catch {
            fail("percent clamping", "threw \(error)")
        }
    }

    private static func rateLimitedAndWorstMeter() {
        let limited = UsageMeter(status: .rateLimited, percent: 10, resetsAt: Date().addingTimeInterval(60))
        let snapshot = UsageSnapshot(
            rolling: UsageMeter(status: .ok, percent: 95, resetsAt: nil),
            weekly: limited,
            monthly: UsageMeter(status: .ok, percent: 42, resetsAt: nil)
        )
        check(limited.isRateLimited, "rate-limited flag")
        check(limited.isCritical, "rate-limited is critical")
        equal(snapshot.worst.status, .rateLimited, "worst meter is rate-limited")
        equal(snapshot.meters.map(\.id), ["rolling", "weekly", "monthly"], "meter row ids")
        equal(snapshot.meters.map(\.title), ["5 часов", "Неделя", "Месяц"], "meter row titles")
    }

    private static func trayMeterSelection() {
        let snapshot = UsageSnapshot(
            rolling: UsageMeter(status: .ok, percent: 8, resetsAt: nil),
            weekly: UsageMeter(status: .ok, percent: 3, resetsAt: nil),
            monthly: UsageMeter(status: .ok, percent: 49, resetsAt: nil)
        )
        equal(snapshot.meter(for: .rolling), snapshot.rolling, "tray selection rolling")
        equal(snapshot.meter(for: .weekly), snapshot.weekly, "tray selection weekly")
        equal(snapshot.meter(for: .monthly), snapshot.monthly, "tray selection monthly")
        equal(snapshot.meter(for: .auto), snapshot.worst, "tray selection auto equals worst")
        equal(snapshot.meter(for: .auto).percent, 49, "tray auto picks highest percent")

        let limitedSnapshot = UsageSnapshot(
            rolling: UsageMeter(status: .ok, percent: 20, resetsAt: nil),
            weekly: UsageMeter(status: .rateLimited, percent: 5, resetsAt: nil),
            monthly: UsageMeter(status: .ok, percent: 49, resetsAt: nil)
        )
        equal(limitedSnapshot.meter(for: .auto), limitedSnapshot.weekly,
              "tray auto prefers rate-limited over higher percent")
        equal(limitedSnapshot.meter(for: .monthly), limitedSnapshot.monthly,
              "tray monthly ignores rate-limited weekly")

        equal(TrayMeter.allCases.count, 4, "TrayMeter has four cases")
        equal(TrayMeter.allCases.map(\.rawValue).sorted(),
              ["auto", "monthly", "rolling", "weekly"], "TrayMeter raw values")
        check(TrayMeter.allCases.allSatisfy { $0.id == $0.rawValue }, "TrayMeter id equals rawValue")
        check(TrayMeter.allCases.allSatisfy { !$0.title.isEmpty }, "TrayMeter titles are non-empty")
        check(TrayMeter.allCases.allSatisfy { item in
            item.title.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        }, "TrayMeter titles are Russian")
        equal(TrayMeter.`default`, .rolling, "default tray selection is rolling")
    }

    private static func rollingWindowFraction() {
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        func meter(resetsAt: Date?) -> UsageMeter {
            UsageMeter(status: .ok, percent: 8, resetsAt: resetsAt)
        }
        equal(AppConfig.rollingWindowDuration, 18_000, "rolling window duration is 5 hours")
        equal(AppDefaultsKey.trayCountdown, "trayCountdown", "trayCountdown defaults key")

        near(meter(resetsAt: now.addingTimeInterval(5 * 3_600)).rollingWindowFraction(now: now),
             1, accuracy: 0.0001, "full 5 hours remaining gives fraction 1")
        near(meter(resetsAt: now.addingTimeInterval(2.5 * 3_600)).rollingWindowFraction(now: now),
             0.5, accuracy: 0.0001, "2.5 hours remaining gives fraction 0.5")
        // One hour out of the five-hour window is 1/5 (the task text's "1/6"
        // contradicts the specified fraction = remaining / 5h).
        near(meter(resetsAt: now.addingTimeInterval(3_600)).rollingWindowFraction(now: now),
             1.0 / 5.0, accuracy: 0.0001, "1 hour remaining gives fraction 1/5")
        near(meter(resetsAt: now).rollingWindowFraction(now: now),
             0, accuracy: 0.0001, "reset now gives fraction 0")
        near(meter(resetsAt: now.addingTimeInterval(-3_600)).rollingWindowFraction(now: now),
             0, accuracy: 0.0001, "past reset is clamped to 0")
        near(meter(resetsAt: now.addingTimeInterval(10 * 3_600)).rollingWindowFraction(now: now),
             1, accuracy: 0.0001, "10 hours remaining is clamped to 1")
        check(meter(resetsAt: nil).rollingWindowFraction(now: now) == nil,
              "unknown reset time gives nil fraction")
    }

    // MARK: - URLProtocol mock

    private final class MockResponseBox: @unchecked Sendable {
        static let shared = MockResponseBox()
        private let lock = NSLock()
        private var statusCode = 200
        private var payload = Data()
        private var lastHeaders: [String: String] = [:]

        func configure(statusCode: Int, payload: Data) {
            lock.lock()
            defer { lock.unlock() }
            self.statusCode = statusCode
            self.payload = payload
            self.lastHeaders = [:]
        }

        func response() -> (statusCode: Int, payload: Data) {
            lock.lock()
            defer { lock.unlock() }
            return (statusCode, payload)
        }

        func record(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            lastHeaders = request.allHTTPHeaderFields ?? [:]
        }

        func headers() -> [String: String] {
            lock.lock()
            defer { lock.unlock() }
            return lastHeaders
        }
    }

    private final class MockURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let box = MockResponseBox.shared
            box.record(request)
            let responseData = box.response()
            let response = HTTPURLResponse(
                url: request.url ?? AppConfig.usageEndpoint,
                statusCode: responseData.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData.payload)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private static func makeService() -> GoUsageService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return GoUsageService(
            keyProvider: { "oc_sk_test_key" },
            session: URLSession(configuration: configuration)
        )
    }

    private static func successThroughMockAndHeaders() async {
        MockResponseBox.shared.configure(statusCode: 200, payload: Data(livePayload.utf8))
        do {
            let snapshot = try await makeService().fetch()
            equal(snapshot.rolling.percent, 8, "mock success rolling percent")
            equal(snapshot.weekly.percent, 3, "mock success weekly percent")
            equal(snapshot.monthly.percent, 49, "mock success monthly percent")
            let headers = MockResponseBox.shared.headers()
            equal(headers["Authorization"], "Bearer oc_sk_test_key", "mock Authorization header")
            equal(headers["User-Agent"], AppConfig.userAgent, "mock User-Agent header")
        } catch {
            fail("mock success", "threw \(error)")
        }
    }

    private static func unauthorizedMapsToInvalidKey() async {
        MockResponseBox.shared.configure(statusCode: 401, payload: Data())
        do {
            _ = try await makeService().fetch()
            fail("401 → .invalidKey", "no error thrown")
        } catch let error as UsageError {
            if case .invalidKey = error {
                TestSupport.shared.pass("401 → .invalidKey")
            } else {
                fail("401 → .invalidKey", "got \(error)")
            }
        } catch {
            fail("401 → .invalidKey", "unexpected \(error)")
        }
    }

    private static func forbiddenMapsToNoSubscription() async {
        let body = #"{"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}"#
        MockResponseBox.shared.configure(statusCode: 403, payload: Data(body.utf8))
        do {
            _ = try await makeService().fetch()
            fail("403 → .noSubscription", "no error thrown")
        } catch let error as UsageError {
            if case .noSubscription(let message) = error {
                equal(message, "OpenCode Go subscription required.", "403 → .noSubscription(message)")
            } else {
                fail("403 → .noSubscription", "got \(error)")
            }
        } catch {
            fail("403 → .noSubscription", "unexpected \(error)")
        }
    }

    private static func serverErrorMapsToNetwork() async {
        MockResponseBox.shared.configure(statusCode: 500, payload: Data())
        do {
            _ = try await makeService().fetch()
            fail("500 → .network", "no error thrown")
        } catch let error as UsageError {
            if case .network = error {
                TestSupport.shared.pass("500 → .network")
            } else {
                fail("500 → .network", "got \(error)")
            }
        } catch {
            fail("500 → .network", "unexpected \(error)")
        }
    }

    private static func decodeFailureMapsToDecoding() async {
        MockResponseBox.shared.configure(statusCode: 200, payload: Data(#"{"usage":"broken"}"#.utf8))
        do {
            _ = try await makeService().fetch()
            fail("bad JSON → .decoding", "no error thrown")
        } catch let error as UsageError {
            if case .decoding = error {
                TestSupport.shared.pass("bad JSON → .decoding")
            } else {
                fail("bad JSON → .decoding", "got \(error)")
            }
        } catch {
            fail("bad JSON → .decoding", "unexpected \(error)")
        }
    }

    private static func keyProviderErrorIsPropagated() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let service = GoUsageService(
            keyProvider: { throw UsageError.missingKey },
            session: URLSession(configuration: configuration)
        )
        do {
            _ = try await service.fetch()
            fail("keyProvider error propagation", "no error thrown")
        } catch let error as UsageError {
            if case .missingKey = error {
                TestSupport.shared.pass("keyProvider error propagation")
            } else {
                fail("keyProvider error propagation", "got \(error)")
            }
        } catch {
            fail("keyProvider error propagation", "unexpected \(error)")
        }
    }
}

// MARK: - Optional live smoke (never prints the key or request headers)

func liveSmoke() async {
    guard ProcessInfo.processInfo.environment["OPENCODE_LIVE_SMOKE"] == "1" else {
        print("[SKIP] live smoke")
        return
    }
    do {
        let store = CredentialStore()
        let service = GoUsageService(keyProvider: { try store.goAPIKey() })
        let snapshot = try await service.fetch()
        let meters = [
            ("rolling", snapshot.rolling),
            ("weekly", snapshot.weekly),
            ("monthly", snapshot.monthly),
        ]
        for (name, meter) in meters {
            print("[SMOKE] \(name): percent=\(meter.percent) status=\(meter.status.rawValue)")
            check(meter.percent >= 0 && meter.percent <= 100, "smoke \(name) percent in 0...100")
        }

        let activity = try ActivityService().load(days: 30)
        print("[SMOKE] activity: source=\(activity.source.rawValue) messages=\(activity.totalMessages) "
            + "events=\(activity.events.count) tokens=\(activity.totalTokens) cost=\(activity.totalCost) "
            + "daily=\(activity.daily.count) monthly=\(activity.monthly.count)")
        check(activity.totalMessages > 0, "smoke activity has messages")
    } catch {
        fail("live smoke", "\(error.localizedDescription)")
    }
}
