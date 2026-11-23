import Foundation
import OpenCodeLimitsCore

// MARK: - Activity aggregation checks

enum ActivityAggregationTests {
    private static let now = Date(timeIntervalSince1970: 1_764_000_000)

    private static var calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }()

    private static func event(
        id: String,
        offset: TimeInterval,
        tokens: TokenBreakdown,
        cost: Double = 0,
        session: String = "s1",
        model: String = "big-pickle",
        title: String = "Сессия",
        project: String = "Проект"
    ) -> UsageEvent {
        makeEvent(
            id: id,
            date: now.addingTimeInterval(offset),
            tokens: tokens,
            cost: cost,
            session: session,
            model: model,
            title: title,
            project: project
        )
    }

    private static func makeEvent(
        id: String,
        date: Date,
        tokens: TokenBreakdown,
        cost: Double = 0,
        session: String = "s1",
        model: String = "big-pickle",
        title: String = "Сессия",
        project: String = "Проект"
    ) -> UsageEvent {
        UsageEvent(
            id: id,
            date: date,
            tokens: tokens,
            cost: cost,
            providerID: "opencode",
            modelID: model,
            sessionID: session,
            sessionTitle: title,
            projectName: project
        )
    }

    static func run() {
        tokenBreakdownTotal()
        aggregationTotalsAndDuplicateSuppression()
        dailyBucketsAreZeroFilledAndAscending()
        hourlyBucketsCoverLastFiveHours()
        monthlyBucketsSpanWholeEventRange()
        dailyBucketsAreCappedAtNinety()
        modelsGroupingAndSessionLimit()
        emptySnapshot()
        missingDatabaseReturnsEmpty()
    }

    private static func tokenBreakdownTotal() {
        let tokens = TokenBreakdown(input: 11_004, output: 52, reasoning: 3, cacheRead: 448, cacheWrite: 7)
        equal(tokens.total, 11_514, "TokenBreakdown.total includes cache")
        equal(TokenBreakdown().total, 0, "TokenBreakdown.total of empty breakdown")
    }

    private static func aggregationTotalsAndDuplicateSuppression() {
        let first = event(id: "m1", offset: -10, tokens: TokenBreakdown(input: 100))
        let duplicate = event(id: "m1", offset: -10, tokens: TokenBreakdown(input: 100))
        let second = event(id: "m2", offset: -20, tokens: TokenBreakdown(output: 50), cost: 0.5)
        let snapshot = ActivityService.aggregate(
            events: [first, duplicate, second], days: 3, now: now, calendar: calendar
        )
        equal(snapshot.events.count, 2, "duplicate event ids suppressed")
        equal(snapshot.totalTokens, 150, "aggregated total tokens")
        equal(snapshot.totalMessages, 2, "aggregated total messages")
        near(snapshot.totalCost, 0.5, accuracy: 0.0001, "aggregated total cost")
        equal(snapshot.generatedAt, now, "aggregated generatedAt")
        equal(snapshot.monthly.count, 1, "monthly buckets for same-month events")
    }

    private static func dailyBucketsAreZeroFilledAndAscending() {
        let today = event(id: "today", offset: 0, tokens: TokenBreakdown(input: 8))
        let older = event(id: "older", offset: -86_400, tokens: TokenBreakdown(input: 5))
        let snapshot = ActivityService.aggregate(
            events: [today, older], days: 7, now: now, calendar: calendar
        )
        equal(snapshot.daily.count, 7, "seven daily buckets")
        for index in 1..<snapshot.daily.count {
            check(snapshot.daily[index - 1].start < snapshot.daily[index].start, "daily buckets ascending")
            equal(snapshot.daily[index - 1].end, snapshot.daily[index].start, "daily buckets contiguous")
        }
        equal(snapshot.daily.last!.tokens, 8, "today bucket tokens")
        equal(snapshot.daily.last!.messages, 1, "today bucket messages")
        equal(snapshot.daily[snapshot.daily.count - 2].tokens, 5, "yesterday bucket tokens")
        check(snapshot.daily.prefix(5).allSatisfy { $0.messages == 0 && $0.tokens == 0 }, "empty days zero-filled")
    }

    private static func hourlyBucketsCoverLastFiveHours() {
        let current = event(id: "now", offset: 0, tokens: TokenBreakdown(output: 12))
        let snapshot = ActivityService.aggregate(events: [current], days: 1, now: now, calendar: calendar)
        equal(snapshot.hourly.count, 5, "five hourly buckets")
        equal(snapshot.hourly.last!.tokens, 12, "current hour bucket tokens")
        equal(snapshot.hourly.last!.messages, 1, "current hour bucket messages")
        check(snapshot.hourly.dropLast().allSatisfy { $0.messages == 0 }, "earlier hours zero-filled")
        for bucket in snapshot.hourly {
            near(bucket.end.timeIntervalSince(bucket.start), 3_600, accuracy: 1, "hourly bucket length")
        }
    }

    private static func monthlyBucketsSpanWholeEventRange() {
        let january = calendar.date(from: DateComponents(year: 2025, month: 1, day: 10, hour: 12))!
        let march = calendar.date(from: DateComponents(year: 2025, month: 3, day: 20, hour: 12))!
        let events = [
            makeEvent(id: "jan", date: january, tokens: TokenBreakdown(input: 4)),
            makeEvent(id: "mar", date: march, tokens: TokenBreakdown(input: 9)),
            makeEvent(id: "jan", date: january, tokens: TokenBreakdown(input: 4)),
        ]
        let snapshot = ActivityService.aggregate(events: events, days: 30, now: now, calendar: calendar)
        equal(snapshot.monthly.count, 3, "monthly buckets include zero-filled gap month")
        equal(snapshot.monthly.map(\.tokens), [4, 0, 9], "monthly bucket tokens")
        equal(snapshot.monthly.map(\.messages), [1, 0, 1], "monthly bucket messages")
        let januaryStart = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        let aprilStart = calendar.date(from: DateComponents(year: 2025, month: 4, day: 1))!
        equal(snapshot.monthly.first!.start, januaryStart, "monthly first bucket starts at local month boundary")
        equal(snapshot.monthly.last!.end, aprilStart, "monthly last bucket ends at local month boundary")
        for index in 1..<snapshot.monthly.count {
            equal(snapshot.monthly[index - 1].end, snapshot.monthly[index].start, "monthly buckets contiguous")
        }
    }

    private static func dailyBucketsAreCappedAtNinety() {
        let old = event(id: "old", offset: -365 * 86_400, tokens: TokenBreakdown(input: 7))
        let snapshot = ActivityService.aggregate(
            events: [old], days: 3_650, now: now, calendar: calendar
        )
        equal(snapshot.daily.count, 90, "daily buckets capped at 90 for 3650 days")
        equal(snapshot.totalTokens, 7, "totals include events beyond the daily cap")
        equal(snapshot.totalMessages, 1, "message count includes events beyond the daily cap")
        equal(snapshot.monthly.count, 1, "monthly covers whole event range")
        equal(snapshot.models.count, 1, "models cover whole event range")
    }

    private static func modelsGroupingAndSessionLimit() {
        var events: [UsageEvent] = [
            event(id: "a", offset: -100, tokens: TokenBreakdown(input: 10), session: "s1", model: "big-pickle"),
            event(id: "b", offset: -50, tokens: TokenBreakdown(input: 20), session: "s2", model: "big-pickle"),
            event(id: "c", offset: -10, tokens: TokenBreakdown(input: 5), session: "s3", model: "other"),
        ]
        for index in 0..<15 {
            events.append(
                event(id: "extra-\(index)", offset: Double(-200 - index), tokens: TokenBreakdown(input: 1),
                      session: "extra-\(index)", model: "other")
            )
        }
        let snapshot = ActivityService.aggregate(events: events, days: 30, now: now, calendar: calendar)
        equal(snapshot.models.count, 2, "two model buckets")
        equal(snapshot.models.first?.modelID, "big-pickle", "top model by tokens")
        equal(snapshot.models.first?.tokens, 30, "top model tokens")
        equal(snapshot.models.first?.messages, 2, "top model messages")
        equal(snapshot.sessions.count, 12, "sessions capped at 12")
        equal(snapshot.sessions.first?.id, "s3", "most recent session first")
        equal(snapshot.sessions.first?.tokens, 5, "most recent session tokens")
    }

    private static func emptySnapshot() {
        let empty = ActivitySnapshot.empty
        check(empty.events.isEmpty, "empty snapshot events")
        check(empty.daily.isEmpty, "empty snapshot daily")
        check(empty.hourly.isEmpty, "empty snapshot hourly")
        check(empty.monthly.isEmpty, "empty snapshot monthly")
        check(empty.models.isEmpty, "empty snapshot models")
        check(empty.sessions.isEmpty, "empty snapshot sessions")
        equal(empty.totalTokens, 0, "empty snapshot total tokens")
        equal(empty.totalCost, 0, "empty snapshot total cost")
        equal(empty.totalMessages, 0, "empty snapshot total messages")

        let aggregated = ActivityService.aggregate(events: [], days: 3, now: now, calendar: calendar)
        check(aggregated.events.isEmpty, "aggregated empty events")
        equal(aggregated.daily.count, 3, "aggregated empty daily buckets")
        check(aggregated.monthly.isEmpty, "aggregated empty monthly buckets")
        equal(aggregated.totalTokens, 0, "aggregated empty total tokens")
        check(aggregated.daily.allSatisfy { $0.messages == 0 && $0.tokens == 0 }, "aggregated empty days zero")
    }

    private static func missingDatabaseReturnsEmpty() {
        let missing = "/tmp/opencode-limits-no-such-file-\(UUID().uuidString).db"
        do {
            let brokenAPI = LocalAPIService(cliPath: "/nonexistent/opencode-cli")
            let snapshot = try ActivityService(dbPath: missing, apiService: brokenAPI).load(days: 7)
            check(snapshot.events.isEmpty, "missing DB returns empty events")
            equal(snapshot.totalTokens, 0, "missing DB returns zero tokens")
            equal(snapshot.source, .database, "missing DB snapshot source is database")
        } catch {
            fail("missing database", "threw \(error)")
        }
    }
}

// MARK: - Single executable entry point

@main
struct TestRunner {
    static func main() async {
        ActivityAggregationTests.run()
        await UsageDecodingTests.run()
        await LocalAPITests.run()
        PowerTests.run()
        await liveSmoke()
        TestSupport.shared.finish()
    }
}
