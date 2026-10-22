import Foundation

public enum SyncInterval: String, Codable, CaseIterable, Sendable, Identifiable {
    case hourly, sixHours, daily, manual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hourly: "Every hour"
        case .sixHours: "Every 6 hours"
        case .daily: "Daily"
        case .manual: "Manual"
        }
    }

    public var seconds: TimeInterval? {
        switch self {
        case .hourly: 3600
        case .sixHours: 6 * 3600
        case .daily: 24 * 3600
        case .manual: nil
        }
    }
}

public enum CommentLimit: Int, Codable, CaseIterable, Sendable, Identifiable {
    case ten = 10, twenty = 20, all = 0

    public var id: Int { rawValue }
    public var label: String { self == .all ? "All" : "\(rawValue)" }
    /// Number of comments to store; `nil` means everything Reddit returns.
    public var storedLimit: Int? { self == .all ? nil : rawValue }
    /// `limit=` sent to `/comments/{id}`.
    public var requestLimit: Int { self == .all ? 500 : rawValue }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var weights: RelevanceWeights = .default
    public var boostKeywords: [String] = ["MSTP", "interviews", "Anki", "research", "match"]
    public var hideImageAndMemePosts: Bool = true
    public var minimumUpvotes: Int = 25
    public var syncInterval: SyncInterval = .sixHours
    public var threadsPerSubreddit: Int = 250
    public var commentsPerThread: CommentLimit = .twenty
    public var syncFromMenuBar: Bool = false
    public var notifyOnKeywordMatch: Bool = false
    public var indexInSpotlight: Bool = false
    public var redditUsername: String = ""
    public var hasCompletedOnboarding: Bool = false

    public static let threadLimitChoices = [100, 250, 1000]

    public init() {}

    public var userAgent: String {
        let user = redditUsername.trimmingCharacters(in: .whitespaces)
        return "macos:com.naren.rounds:v1.0 (by /u/\(user.isEmpty ? "rounds_app" : user))"
    }

    // Decode leniently so new settings never wipe out saved ones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.defaults
        weights = try c.decodeIfPresent(RelevanceWeights.self, forKey: .weights) ?? d.weights
        boostKeywords = try c.decodeIfPresent([String].self, forKey: .boostKeywords) ?? d.boostKeywords
        hideImageAndMemePosts = try c.decodeIfPresent(Bool.self, forKey: .hideImageAndMemePosts) ?? d.hideImageAndMemePosts
        minimumUpvotes = try c.decodeIfPresent(Int.self, forKey: .minimumUpvotes) ?? d.minimumUpvotes
        syncInterval = try c.decodeIfPresent(SyncInterval.self, forKey: .syncInterval) ?? d.syncInterval
        threadsPerSubreddit = try c.decodeIfPresent(Int.self, forKey: .threadsPerSubreddit) ?? d.threadsPerSubreddit
        commentsPerThread = try c.decodeIfPresent(CommentLimit.self, forKey: .commentsPerThread) ?? d.commentsPerThread
        syncFromMenuBar = try c.decodeIfPresent(Bool.self, forKey: .syncFromMenuBar) ?? d.syncFromMenuBar
        notifyOnKeywordMatch = try c.decodeIfPresent(Bool.self, forKey: .notifyOnKeywordMatch) ?? d.notifyOnKeywordMatch
        indexInSpotlight = try c.decodeIfPresent(Bool.self, forKey: .indexInSpotlight) ?? d.indexInSpotlight
        redditUsername = try c.decodeIfPresent(String.self, forKey: .redditUsername) ?? d.redditUsername
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
    }

    private static let defaults = AppSettings()
}

/// Persists `AppSettings` as JSON in `UserDefaults`.
public struct SettingsStore: Sendable {
    private let key = "RoundsSettings.v1"
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
