import Foundation
import GRDB

// MARK: - Enums

public enum TimeWindow: String, Codable, CaseIterable, Sendable, Identifiable {
    case week, month, year, all

    public var id: String { rawValue }

    /// Value of the `t=` parameter on `/r/{sub}/top`.
    public var apiValue: String { rawValue }

    public var label: String {
        switch self {
        case .week: "Past week"
        case .month: "Past month"
        case .year: "Past year"
        case .all: "All time"
        }
    }

    /// Phrase used in "why it surfaced" strings, e.g. "this month".
    public var phrase: String {
        switch self {
        case .week: "this week"
        case .month: "this month"
        case .year: "this year"
        case .all: "of all time"
        }
    }
}

public enum ThreadKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case discussion, question, resource

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .discussion: "Discussion"
        case .question: "Question"
        case .resource: "Resource"
        }
    }
}

// MARK: - Subreddit

public struct Subreddit: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "subreddit"

    /// Lower-cased name, used as the primary key so duplicates are rejected case-insensitively.
    public var id: String
    /// Display name with Reddit's canonical casing (e.g. "medicalschool", "MCAT").
    public var name: String
    public var colorHex: String
    public var window: TimeWindow
    public var keywords: [String]
    public var includeKinds: Set<ThreadKind>
    public var lastSynced: Date?
    public var lastError: String?
    public var isEnabled: Bool
    public var sortIndex: Int

    public init(
        name: String,
        colorHex: String,
        window: TimeWindow = .month,
        keywords: [String] = [],
        includeKinds: Set<ThreadKind> = Set(ThreadKind.allCases),
        lastSynced: Date? = nil,
        lastError: String? = nil,
        isEnabled: Bool = true,
        sortIndex: Int = 0
    ) {
        self.id = name.lowercased()
        self.name = name
        self.colorHex = colorHex
        self.window = window
        self.keywords = keywords
        self.includeKinds = includeKinds
        self.lastSynced = lastSynced
        self.lastError = lastError
        self.isEnabled = isEnabled
        self.sortIndex = sortIndex
    }

    public static let defaultNames = ["mdphd", "medicalschool", "medicine", "medschool", "mcat"]
    public static let suggestedNames = ["premed", "Residency", "step1", "USMLE"]

    /// Palette used when assigning colors to new subreddits.
    public static let palette = [
        "#0B6E69", "#D9822B", "#5B5BD6", "#C2410C", "#0E7490",
        "#9D174D", "#4D7C0F", "#7C3AED", "#B45309", "#2563EB",
    ]

    public static func color(forIndex index: Int) -> String {
        palette[((index % palette.count) + palette.count) % palette.count]
    }
}

// MARK: - Thread

public struct RedditThread: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "thread"

    public var id: String
    /// Lower-cased subreddit id (joins `subreddit.id`).
    public var sub: String
    /// Subreddit name as Reddit spells it.
    public var subName: String
    public var title: String
    public var body: String
    public var author: String
    public var score: Int
    public var numComments: Int
    public var createdUTC: Date
    public var permalink: String
    public var postURL: String?
    public var kind: ThreadKind
    public var relevance: Double
    public var why: String
    public var matchedKeywords: [String]
    public var isSaved: Bool
    public var savedOnReddit: Bool
    public var linkCount: Int
    public var maxDepth: Int
    public var isImageOnly: Bool
    public var commentsFetchedAt: Date?
    public var firstSeenAt: Date
    public var updatedAt: Date

    public init(
        id: String, sub: String, subName: String, title: String, body: String, author: String,
        score: Int, numComments: Int, createdUTC: Date, permalink: String, postURL: String? = nil,
        kind: ThreadKind = .discussion, relevance: Double = 0, why: String = "",
        matchedKeywords: [String] = [], isSaved: Bool = false, savedOnReddit: Bool = false,
        linkCount: Int = 0, maxDepth: Int = 0, isImageOnly: Bool = false,
        commentsFetchedAt: Date? = nil, firstSeenAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.sub = sub
        self.subName = subName
        self.title = title
        self.body = body
        self.author = author
        self.score = score
        self.numComments = numComments
        self.createdUTC = createdUTC
        self.permalink = permalink
        self.postURL = postURL
        self.kind = kind
        self.relevance = relevance
        self.why = why
        self.matchedKeywords = matchedKeywords
        self.isSaved = isSaved
        self.savedOnReddit = savedOnReddit
        self.linkCount = linkCount
        self.maxDepth = maxDepth
        self.isImageOnly = isImageOnly
        self.commentsFetchedAt = commentsFetchedAt
        self.firstSeenAt = firstSeenAt
        self.updatedAt = updatedAt
    }

    public var redditURL: URL? {
        URL(string: "https://www.reddit.com" + permalink)
    }
}

// MARK: - Comment

public struct Comment: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "comment"

    public var id: String
    public var threadId: String
    public var author: String
    public var body: String
    public var score: Int
    public var depth: Int
    /// Order in which Reddit returned the comment (top sort, depth first).
    public var position: Int

    public init(id: String, threadId: String, author: String, body: String, score: Int, depth: Int, position: Int) {
        self.id = id
        self.threadId = threadId
        self.author = author
        self.body = body
        self.score = score
        self.depth = depth
        self.position = position
    }
}

// MARK: - Resource

public struct Resource: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "resource"

    /// `threadId|url`, unique per thread.
    public var id: String
    public var url: String
    public var domain: String
    public var title: String
    public var threadId: String
    public var sourceCommentId: String?

    public init(url: String, domain: String, title: String, threadId: String, sourceCommentId: String?) {
        self.id = "\(threadId)|\(url)"
        self.url = url
        self.domain = domain
        self.title = title
        self.threadId = threadId
        self.sourceCommentId = sourceCommentId
    }
}

/// Everything the detail pane needs for one thread.
public struct ThreadDetail: Sendable, Equatable {
    public var thread: RedditThread
    public var comments: [Comment]
    public var resources: [Resource]
}
