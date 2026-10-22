import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RoundsCore

/// Canned Reddit responses, shaped like the real API output.
enum Fixtures {
    static func post(
        id: String, sub: String = "mdphd", title: String, selftext: String = "", score: Int, comments: Int,
        url: String? = nil, isSelf: Bool = true, hint: String? = nil, flair: String? = nil, stickied: Bool = false
    ) -> String {
        let urlValue = url ?? "https://www.reddit.com/r/\(sub)/comments/\(id)/slug/"
        let hintJSON = hint.map { "\"post_hint\": \"\($0)\"," } ?? ""
        let flairJSON = flair.map { "\"link_flair_text\": \"\($0)\"," } ?? "\"link_flair_text\": null,"
        return """
        {"kind": "t3", "data": {
            "id": "\(id)", "name": "t3_\(id)", "subreddit": "\(sub)", "title": \(jsonString(title)),
            "selftext": \(jsonString(selftext)), "author": "user_\(id)", "score": \(score),
            "num_comments": \(comments), "created_utc": 1760000000.0,
            "permalink": "/r/\(sub)/comments/\(id)/slug/", "url": \(jsonString(urlValue)),
            \(hintJSON) \(flairJSON)
            "is_self": \(isSelf), "is_video": false, "stickied": \(stickied), "over_18": false
        }}
        """
    }

    static func listing(_ children: [String], after: String? = nil) -> String {
        let afterJSON = after.map { "\"\($0)\"" } ?? "null"
        return """
        {"kind": "Listing", "data": {"after": \(afterJSON), "dist": \(children.count), "children": [\(children.joined(separator: ","))]}}
        """
    }

    static let mdphdTop = listing([
        post(id: "a1", title: "MSTP interviews megathread: share your experiences",
             selftext: "Post your interview experiences here. Spreadsheet: [Interview tracker](https://docs.google.com/spreadsheets/d/abc123/edit?usp=sharing&utm_source=reddit)",
             score: 900, comments: 240),
        post(id: "a2", title: "How do I balance research and Step 1 studying?", score: 300, comments: 80),
        post(id: "a3", title: "Funny lab meme", score: 1200, comments: 15, url: "https://i.redd.it/xyz.png", isSelf: false, hint: "image"),
        post(id: "a4", title: "Reflections after my first year", selftext: "Long story about my PhD years.", score: 40, comments: 12),
        post(id: "a5", title: "low effort", score: 3, comments: 1),
    ])

    static let mdphdHot = listing([
        post(id: "pin", title: "Weekly thread", score: 5, comments: 2, stickied: true),
        post(id: "a6", title: "Anki deck for biochem", selftext: "Here it is: https://ankiweb.net/shared/info/12345 enjoy!", score: 60, comments: 9),
    ])

    static func comments(for postJSON: String, commentsJSON: String) -> String {
        "[\(listing([postJSON])), \(commentsJSON)]"
    }

    static let a1Comments = comments(
        for: post(id: "a1", title: "MSTP interviews megathread: share your experiences",
                  selftext: "Post your interview experiences here. Spreadsheet: [Interview tracker](https://docs.google.com/spreadsheets/d/abc123/edit?usp=sharing&utm_source=reddit)",
                  score: 900, comments: 240),
        commentsJSON: """
        {"kind": "Listing", "data": {"after": null, "children": [
          {"kind": "t1", "data": {"id": "c1", "author": "alpha", "body": "My MSTP interview at WashU was great. Notes: https://example.com/notes.pdf?fbclid=XYZ", "score": 120, "depth": 0,
            "replies": {"kind": "Listing", "data": {"after": null, "children": [
              {"kind": "t1", "data": {"id": "c2", "author": "beta", "body": "Same! Also see [this guide](https://www.example.org/guide/)", "score": 40, "depth": 1,
                "replies": {"kind": "Listing", "data": {"after": null, "children": [
                  {"kind": "t1", "data": {"id": "c3", "author": "gamma", "body": "Thanks for sharing", "score": 10, "depth": 2, "replies": ""}}
                ]}}}}
            ]}}}},
          {"kind": "t1", "data": {"id": "c4", "author": "delta", "body": "Duplicate link https://example.com/notes.pdf", "score": 30, "depth": 0, "replies": ""}},
          {"kind": "more", "data": {"id": "m1", "count": 12, "children": ["x", "y"]}}
        ]}}
        """
    )

    static func simpleComments(postID: String, title: String, score: Int, comments: Int, selftext: String = "") -> String {
        Fixtures.comments(
            for: post(id: postID, title: title, selftext: selftext, score: score, comments: comments),
            commentsJSON: """
            {"kind": "Listing", "data": {"after": null, "children": [
              {"kind": "t1", "data": {"id": "\(postID)-c1", "author": "x", "body": "Helpful thread about research", "score": 5, "depth": 0, "replies": ""}}
            ]}}
            """
        )
    }

    static let aboutPublic = """
    {"kind": "t5", "data": {"display_name": "premed", "subreddit_type": "public", "subscribers": 500000, "public_description": "Premed", "quarantine": false}}
    """
    static let aboutPrivateBody = #"{"reason": "private", "message": "Forbidden", "error": 403}"#
    static let aboutBannedBody = #"{"reason": "banned", "message": "Not Found", "error": 404}"#
    static let aboutMissingBody = #"{"message": "Not Found", "error": 404}"#
    static let searchRedirectListing = listing([])

    static let token = #"{"access_token": "app-token", "token_type": "bearer", "expires_in": 86400, "scope": "*"}"#

    private static func jsonString(_ s: String) -> String {
        let data = try! JSONEncoder().encode(s)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Routes requests to canned responses by URL path.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Canned {
        var status: Int
        var body: String
        var headers: [String: String]
    }

    private let lock = NSLock()
    private var routes: [String: [Canned]] = [:]
    private(set) var requests: [URLRequest] = []

    func on(_ path: String, status: Int = 200, body: String, headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        routes[path, default: []].append(Canned(status: status, body: body, headers: headers))
    }

    private func next(for request: URLRequest) -> Canned {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let path = request.url!.path
        var queue = routes[path] ?? []
        if queue.count > 1 {
            let canned = queue.removeFirst()
            routes[path] = queue
            return canned
        }
        return queue.first ?? Canned(status: 404, body: #"{"message": "Not Found", "error": 404}"#, headers: [:])
    }

    var requestedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return requests.compactMap { $0.url?.path }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let canned = next(for: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: canned.headers)!
        return (Data(canned.body.utf8), response)
    }
}

struct StaticToken: TokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "test-token" }
}

func makeClient(_ transport: MockTransport) -> RedditClient {
    RedditClient(
        transport: transport,
        appTokens: StaticToken(),
        userTokens: StaticToken(),
        limiter: RateLimiter(minimumInterval: 0, sleeper: { _ in }),
        userAgent: { "macos:com.naren.rounds:v1.0 (by /u/tester)" },
        backoffBase: 0
    )
}
