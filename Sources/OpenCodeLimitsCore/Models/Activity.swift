import Foundation

/// Where activity data was obtained from.
public enum ActivitySource: String, Sendable {
    case api = "api"
    case database = "database"

    public var title: String {
        switch self {
        case .api: return "API OpenCode"
        case .database: return "Локальная БД"
        }
    }
}

/// Token counts of a single assistant message. `total` includes cache reads and
/// writes, matching the OpenCode usage accounting.
public struct TokenBreakdown: Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var reasoning: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public var total: Int { input + output + reasoning + cacheRead + cacheWrite }

    public init(input: Int = 0, output: Int = 0, reasoning: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

/// One assistant message rendered as an activity event. Message text is never
/// loaded from the database, so it cannot leak into this model.
public struct UsageEvent: Sendable, Identifiable {
    public let id: String
    public let date: Date
    public let tokens: TokenBreakdown
    public let cost: Double
    public let providerID: String
    public let modelID: String
    public let sessionID: String
    public let sessionTitle: String
    public let projectName: String

    public init(
        id: String,
        date: Date,
        tokens: TokenBreakdown,
        cost: Double = 0,
        providerID: String = "",
        modelID: String = "",
        sessionID: String = "",
        sessionTitle: String = "",
        projectName: String = ""
    ) {
        self.id = id
        self.date = date
        self.tokens = tokens
        self.cost = cost
        self.providerID = providerID
        self.modelID = modelID
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.projectName = projectName
    }
}

/// A time bucket used by the daily and hourly charts.
public struct ActivityBucket: Sendable, Identifiable {
    public let id: Date
    public let start: Date
    public let end: Date
    public var tokens: Int
    public var cost: Double
    public var messages: Int

    public init(id: Date? = nil, start: Date, end: Date, tokens: Int = 0, cost: Double = 0, messages: Int = 0) {
        self.start = start
        self.end = end
        self.id = id ?? start
        self.tokens = tokens
        self.cost = cost
        self.messages = messages
    }
}

/// Aggregated usage for one model.
public struct ModelBucket: Sendable, Identifiable {
    public let id: String
    public let providerID: String
    public let modelID: String
    public var tokens: Int
    public var cost: Double
    public var messages: Int

    public init(
        id: String,
        providerID: String,
        modelID: String,
        tokens: Int = 0,
        cost: Double = 0,
        messages: Int = 0
    ) {
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
        self.tokens = tokens
        self.cost = cost
        self.messages = messages
    }
}

/// Aggregated usage for one session.
public struct SessionSummary: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let project: String
    public let model: String
    public var tokens: Int
    public var cost: Double
    public var messages: Int
    public let lastActive: Date

    public init(
        id: String,
        title: String,
        project: String,
        model: String,
        tokens: Int = 0,
        cost: Double = 0,
        messages: Int = 0,
        lastActive: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.project = project
        self.model = model
        self.tokens = tokens
        self.cost = cost
        self.messages = messages
        self.lastActive = lastActive
    }
}

/// Everything the activity UI needs, computed from assistant messages only.
public struct ActivitySnapshot: Sendable {
    public let events: [UsageEvent]
    public let daily: [ActivityBucket]
    public let hourly: [ActivityBucket]
    /// One bucket per calendar month spanning the whole loaded event range,
    /// in ascending order (unbounded — unlike `daily`, it is not capped).
    public let monthly: [ActivityBucket]
    public let models: [ModelBucket]
    public let sessions: [SessionSummary]
    public let totalTokens: Int
    public let totalCost: Double
    public let totalMessages: Int
    public let generatedAt: Date
    /// Origin of the data: local OpenCode V2 API or the read-only SQLite DB.
    public let source: ActivitySource

    public init(
        events: [UsageEvent] = [],
        daily: [ActivityBucket] = [],
        hourly: [ActivityBucket] = [],
        monthly: [ActivityBucket] = [],
        models: [ModelBucket] = [],
        sessions: [SessionSummary] = [],
        totalTokens: Int = 0,
        totalCost: Double = 0,
        totalMessages: Int = 0,
        generatedAt: Date = Date(),
        source: ActivitySource = .database
    ) {
        self.events = events
        self.daily = daily
        self.hourly = hourly
        self.monthly = monthly
        self.models = models
        self.sessions = sessions
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.totalMessages = totalMessages
        self.generatedAt = generatedAt
        self.source = source
    }

    public static let empty = ActivitySnapshot(
        events: [],
        daily: [],
        hourly: [],
        monthly: [],
        models: [],
        sessions: [],
        totalTokens: 0,
        totalCost: 0,
        totalMessages: 0,
        generatedAt: Date(),
        source: .database
    )
}
