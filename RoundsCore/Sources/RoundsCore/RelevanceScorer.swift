import Foundation

public struct RelevanceWeights: Codable, Equatable, Sendable {
    public var upvotes: Double
    public var discussion: Double
    public var resources: Double
    public var keywords: Double

    public init(upvotes: Double = 0.35, discussion: Double = 0.25, resources: Double = 0.2, keywords: Double = 0.2) {
        self.upvotes = upvotes
        self.discussion = discussion
        self.resources = resources
        self.keywords = keywords
    }

    public static let `default` = RelevanceWeights()
}

/// Per-subreddit maxima used to normalize log-scaled signals.
public struct SubredditStats: Sendable, Equatable {
    public var maxScore: Int
    public var maxComments: Int
    /// Deepest top-listing rank among the subreddit's threads.
    public var maxRank: Int

    public init(maxScore: Int, maxComments: Int, maxRank: Int = 0) {
        self.maxScore = maxScore
        self.maxComments = maxComments
        self.maxRank = maxRank
    }
}

public struct ScoringInput: Sendable {
    public var subName: String
    public var window: TimeWindow
    /// -1 when unknown; `topRank` stands in for it.
    public var score: Int
    public var topRank: Int?
    public var numComments: Int
    public var maxReplyDepth: Int
    public var uniqueLinkCount: Int
    public var title: String
    public var body: String
    public var commentBodies: [String]

    public init(subName: String, window: TimeWindow, score: Int, topRank: Int? = nil, numComments: Int, maxReplyDepth: Int,
                uniqueLinkCount: Int, title: String, body: String, commentBodies: [String]) {
        self.subName = subName
        self.window = window
        self.score = score
        self.topRank = topRank
        self.numComments = numComments
        self.maxReplyDepth = maxReplyDepth
        self.uniqueLinkCount = uniqueLinkCount
        self.title = title
        self.body = body
        self.commentBodies = commentBodies
    }
}

public struct ScoreResult: Sendable, Equatable {
    /// 0–100.
    public var relevance: Double
    public var why: String
    public var matchedKeywords: [String]
    /// Normalized 0–1 signal values.
    public var upvoteSignal: Double
    public var discussionSignal: Double
    public var resourceSignal: Double
    public var keywordSignal: Double
}

public enum RelevanceScorer {
    /// Reply depth at which the depth part of the discussion signal saturates.
    static let depthSaturation = 5.0
    /// Unique link count at which the resource signal saturates.
    static let linkSaturation = 4.0

    public static func score(
        _ input: ScoringInput,
        stats: SubredditStats,
        weights: RelevanceWeights,
        keywords: [String]
    ) -> ScoreResult {
        let upvotes = input.score >= 0
            ? logNormalized(input.score, max: stats.maxScore)
            : rankSignal(input.topRank, maxRank: stats.maxRank)
        let comments = logNormalized(input.numComments, max: stats.maxComments)
        let depth = min(Double(max(input.maxReplyDepth, 0)), depthSaturation) / depthSaturation
        let discussion = 0.7 * comments + 0.3 * depth
        let resources = min(Double(input.uniqueLinkCount), linkSaturation) / linkSaturation

        let matched = matchKeywords(keywords, in: [input.title, input.body] + input.commentBodies)
        // First match counts 0.6, the second brings it to 0.84, then it saturates toward 1.
        let keywordSignal = matched.isEmpty ? 0 : 1 - pow(0.4, Double(matched.count))

        let w = sanitized(weights)
        let total = w.upvotes + w.discussion + w.resources + w.keywords
        let weighted = total > 0
            ? (w.upvotes * upvotes + w.discussion * discussion + w.resources * resources + w.keywords * keywordSignal) / total
            : 0
        let relevance = (min(max(weighted, 0), 1) * 1000).rounded() / 10

        let why = explanation(
            input: input, matched: matched,
            contributions: [
                (.upvotes, w.upvotes * upvotes),
                (.discussion, w.discussion * discussion),
                (.resources, w.resources * resources),
            ]
        )
        return ScoreResult(
            relevance: relevance, why: why, matchedKeywords: matched,
            upvoteSignal: upvotes, discussionSignal: discussion, resourceSignal: resources, keywordSignal: keywordSignal
        )
    }

    /// Case-insensitive whole-word matching. Returns keywords in the order given, without duplicates.
    public static func matchKeywords(_ keywords: [String], in texts: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let haystack = texts.joined(separator: "\n")
        for keyword in keywords {
            let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty, seen.insert(k.lowercased()).inserted else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: k) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            if regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil {
                result.append(k)
            }
        }
        return result
    }

    static func logNormalized(_ value: Int, max maxValue: Int) -> Double {
        let v = Double(Swift.max(value, 0))
        let m = Double(Swift.max(maxValue, value, 0))
        guard m > 0 else { return 0 }
        return log1p(v) / log1p(m)
    }

    /// Without upvote counts, a thread's place in the top listing stands in: #1 scores 1, the last one close to 0.
    static func rankSignal(_ rank: Int?, maxRank: Int) -> Double {
        guard let rank, rank >= 1 else { return 0 }
        let depth = Double(Swift.max(maxRank, rank))
        return 1 - Double(rank - 1) / depth
    }

    private static func sanitized(_ w: RelevanceWeights) -> RelevanceWeights {
        RelevanceWeights(
            upvotes: max(w.upvotes, 0), discussion: max(w.discussion, 0),
            resources: max(w.resources, 0), keywords: max(w.keywords, 0)
        )
    }

    enum Signal { case upvotes, discussion, resources }

    static func explanation(input: ScoringInput, matched: [String], contributions: [(Signal, Double)]) -> String {
        var parts: [String] = []
        let ranked = contributions.filter { $0.1 > 0.0001 }.sorted { $0.1 > $1.1 }
        let sub = "r/\(input.subName)"

        if let lead = ranked.first {
            switch lead.0 {
            case .upvotes:
                parts.append("Top post in \(sub) \(input.window.phrase)")
            case .discussion:
                parts.append("Top discussion in \(sub) \(input.window.phrase)")
            case .resources:
                parts.append(resourcePhrase(input.uniqueLinkCount, sub: sub))
            }
            // Mention a strong secondary signal when it adds information.
            if ranked.count > 1, ranked[1].1 >= lead.1 * 0.6 {
                switch ranked[1].0 {
                case .upvotes where input.score >= 0: parts.append("\(compact(input.score)) upvotes")
                case .upvotes: if let rank = input.topRank { parts.append("#\(rank) of the top posts") }
                case .discussion where input.numComments >= 0: parts.append("\(compact(input.numComments)) comments")
                case .resources where input.uniqueLinkCount > 0:
                    parts.append(input.uniqueLinkCount == 1 ? "1 link shared" : "\(input.uniqueLinkCount) links shared")
                default: break
                }
            }
        } else if matched.isEmpty {
            parts.append("New in \(sub)")
        }

        if !matched.isEmpty {
            parts.append("matches: " + matched.prefix(4).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private static func resourcePhrase(_ count: Int, sub: String) -> String {
        count == 1 ? "Shares a resource in \(sub)" : "Shares \(count) resources in \(sub)"
    }

    static func compact(_ n: Int) -> String {
        if n >= 10_000 { return String(format: "%.0fk", Double(n) / 1000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}
