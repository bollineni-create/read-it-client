import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Read-only operations Rounds performs against Reddit. Rounds never posts, votes or comments.
public protocol RedditAPI: Sendable {
    func top(subreddit: String, window: TimeWindow, limit: Int, after: String?) async throws -> RedditListing<PostThing>
    func hot(subreddit: String, limit: Int) async throws -> RedditListing<PostThing>
    func comments(threadID: String, limit: Int) async throws -> CommentsResponse
    func about(subreddit: String) async throws -> SubredditAbout
    func me() async throws -> RedditIdentity
    func saved(username: String, after: String?) async throws -> RedditListing<PostThing>
}

/// `oauth.reddit.com` client: bearer auth, rate-limit queue, 429 back-off and one retry on 401.
public struct RedditClient: RedditAPI {
    public static let baseURL = URL(string: "https://oauth.reddit.com")!

    private let transport: HTTPTransport
    private let appTokens: TokenProvider
    private let userTokens: TokenProvider?
    private let limiter: RateLimiter
    private let userAgent: @Sendable () -> String
    private let maxRetries: Int
    private let backoffBase: TimeInterval

    public init(
        transport: HTTPTransport,
        appTokens: TokenProvider,
        userTokens: TokenProvider? = nil,
        limiter: RateLimiter = RateLimiter(),
        userAgent: @escaping @Sendable () -> String,
        maxRetries: Int = 4,
        backoffBase: TimeInterval = 2
    ) {
        self.transport = transport
        self.appTokens = appTokens
        self.userTokens = userTokens
        self.limiter = limiter
        self.userAgent = userAgent
        self.maxRetries = maxRetries
        self.backoffBase = backoffBase
    }

    // MARK: Endpoints

    public func top(subreddit: String, window: TimeWindow, limit: Int, after: String?) async throws -> RedditListing<PostThing> {
        var query = [("t", window.apiValue), ("limit", "\(min(limit, 100))"), ("raw_json", "1")]
        if let after { query.append(("after", after)) }
        return try await get("/r/\(subreddit)/top", query: query)
    }

    public func hot(subreddit: String, limit: Int) async throws -> RedditListing<PostThing> {
        try await get("/r/\(subreddit)/hot", query: [("limit", "\(min(limit, 100))"), ("raw_json", "1")])
    }

    public func comments(threadID: String, limit: Int) async throws -> CommentsResponse {
        try await get("/comments/\(threadID)", query: [
            ("sort", "top"), ("limit", "\(limit)"), ("depth", "8"), ("raw_json", "1"),
        ])
    }

    public func about(subreddit: String) async throws -> SubredditAbout {
        let (data, response) = try await perform(path: "/r/\(subreddit)/about", query: [("raw_json", "1")], user: false, allowStatus: [403, 404])
        switch response.statusCode {
        case 200:
            guard let about = try? JSONDecoder().decode(SubredditAbout.self, from: data) else {
                throw RedditError.subredditNotFound(subreddit)
            }
            if about.subredditType == "private" { throw RedditError.subredditPrivate(about.displayName) }
            if about.quarantine { throw RedditError.subredditQuarantined(about.displayName) }
            return about
        case 403:
            let body = try? JSONDecoder().decode(RedditErrorBody.self, from: data)
            if body?.reason == "quarantined" { throw RedditError.subredditQuarantined(subreddit) }
            if body?.reason == "banned" { throw RedditError.subredditBanned(subreddit) }
            throw RedditError.subredditPrivate(subreddit)
        default:
            let body = try? JSONDecoder().decode(RedditErrorBody.self, from: data)
            if body?.reason == "banned" { throw RedditError.subredditBanned(subreddit) }
            throw RedditError.subredditNotFound(subreddit)
        }
    }

    public func me() async throws -> RedditIdentity {
        try await get("/api/v1/me", query: [], user: true)
    }

    public func saved(username: String, after: String?) async throws -> RedditListing<PostThing> {
        var query = [("type", "links"), ("limit", "100"), ("raw_json", "1")]
        if let after { query.append(("after", after)) }
        return try await get("/user/\(username)/saved", query: query, user: true)
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String, query: [(String, String)], user: Bool = false) async throws -> T {
        let (data, _) = try await perform(path: path, query: query, user: user, allowStatus: [])
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RedditError.decoding(path)
        }
    }

    private func perform(path: String, query: [(String, String)], user: Bool, allowStatus: Set<Int>) async throws -> (Data, HTTPURLResponse) {
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.0, value: $0.1) }
        let url = comps.url!

        let tokens: TokenProvider
        if user {
            guard let userTokens else { throw RedditError.notConnected }
            tokens = userTokens
        } else {
            tokens = appTokens
        }

        var refreshedToken = false
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let token = try await tokens.accessToken(forceRefresh: refreshedToken)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            try await limiter.acquire()
            let (data, response) = try await transport.send(request)
            await limiter.update(headers: headerDictionary(response))

            switch response.statusCode {
            case 200..<300:
                return (data, response)
            case 401 where !refreshedToken:
                refreshedToken = true
                continue
            case 401:
                throw RedditError.unauthorized
            case 429, 500, 502, 503, 504:
                guard attempt < maxRetries else {
                    throw response.statusCode == 429 ? RedditError.rateLimited : RedditError.http(response.statusCode)
                }
                let retryAfter = headerDictionary(response)
                    .first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }
                    .flatMap { Double($0.value) }
                let delay = retryAfter ?? backoffBase * pow(2, Double(attempt))
                await limiter.backOff(seconds: delay)
                attempt += 1
                continue
            default:
                if allowStatus.contains(response.statusCode) { return (data, response) }
                throw RedditError.http(response.statusCode)
            }
        }
    }

    private func headerDictionary(_ response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            out["\(key)"] = "\(value)"
        }
        return out
    }
}
