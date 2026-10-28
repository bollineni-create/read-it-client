import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads Reddit's public Atom feeds (`www.reddit.com/…/.rss`), which need no client ID.
///
/// Feeds carry titles, authors, dates and the post and comment text, but no upvote or comment counts and no reply
/// tree. Posts come back with `score` and `numComments` set to -1 ("unknown"); the sync engine ranks them by their
/// position in the top listing instead. Reddit allows few anonymous requests, so a pass fetches comments for at most
/// `commentFetchesPerPass` threads per subreddit and later passes fill in the rest.
public struct RedditFeedClient: RedditAPI {
    public static let baseURL = URL(string: "https://www.reddit.com")!

    private let transport: HTTPTransport
    private let limiter: RateLimiter
    private let userAgent: @Sendable () -> String
    private let maxRetries: Int
    private let backoffBase: TimeInterval

    public init(
        transport: HTTPTransport,
        limiter: RateLimiter = RateLimiter(minimumInterval: 1),
        userAgent: @escaping @Sendable () -> String,
        maxRetries: Int = 4,
        backoffBase: TimeInterval = 5
    ) {
        self.transport = transport
        self.limiter = limiter
        self.userAgent = userAgent
        self.maxRetries = maxRetries
        self.backoffBase = backoffBase
    }

    public var commentFetchesPerPass: Int? { 30 }

    // MARK: Endpoints

    /// Feeds return one page of up to 100 posts and no cursor, so `after` is ignored.
    public func top(subreddit: String, window: TimeWindow, limit: Int, after: String?) async throws -> RedditListing<PostThing> {
        let feed = try await fetch("/r/\(subreddit)/top/.rss", query: [("t", window.apiValue), ("limit", "\(min(max(limit, 1), 100))")], subreddit: subreddit)
        return RedditListing(after: nil, children: feed.entries.compactMap { Self.post(from: $0, subreddit: subreddit) }.map(PostThing.init))
    }

    public func hot(subreddit: String, limit: Int) async throws -> RedditListing<PostThing> {
        let feed = try await fetch("/r/\(subreddit)/hot/.rss", query: [("limit", "\(min(max(limit, 1), 100))")], subreddit: subreddit)
        return RedditListing(after: nil, children: feed.entries.compactMap { Self.post(from: $0, subreddit: subreddit) }.map(PostThing.init))
    }

    /// The thread feed lists the post first, then comments in top order. Comments come back flat (depth 0).
    /// `post` is nil so the sync engine keeps the listing's copy, which carries the subreddit name as you spelled it.
    public func comments(threadID: String, limit: Int) async throws -> CommentsResponse {
        let feed = try await fetch("/comments/\(threadID)/.rss", query: [("sort", "top"), ("limit", "\(min(max(limit, 1), 500))")], subreddit: nil)
        let comments = feed.entries.compactMap(Self.comment(from:))
        return CommentsResponse(post: nil, comments: Array(comments.prefix(limit)))
    }

    public func about(subreddit: String) async throws -> SubredditAbout {
        let feed = try await fetch("/r/\(subreddit)/.rss", query: [("limit", "1")], subreddit: subreddit)
        return SubredditAbout(displayName: subreddit, subredditType: "public", subscribers: nil,
                              publicDescription: feed.title.isEmpty ? nil : feed.title)
    }

    public func me() async throws -> RedditIdentity {
        throw RedditError.needsAPIAccess
    }

    public func saved(username: String, after: String?) async throws -> RedditListing<PostThing> {
        throw RedditError.needsAPIAccess
    }

    // MARK: Plumbing

    private func fetch(_ path: String, query: [(String, String)], subreddit: String?) async throws -> AtomFeed {
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        let url = comps.url!

        var attempt = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
            request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")

            try await limiter.acquire()
            let (data, response) = try await transport.send(request)
            let headers = Self.headerDictionary(response)
            await limiter.update(headers: headers)

            switch response.statusCode {
            case 200..<300:
                // A subreddit that doesn't exist redirects to the subreddit search feed.
                if let subreddit, let final = response.url, final.path.hasPrefix("/subreddits/search") {
                    throw RedditError.subredditNotFound(subreddit)
                }
                guard let feed = AtomFeed.parse(data) else { throw RedditError.decoding(path) }
                return feed
            case 403 where subreddit != nil:
                throw RedditError.subredditPrivate(subreddit!)
            case 404 where subreddit != nil:
                throw RedditError.subredditNotFound(subreddit!)
            case 429, 500, 502, 503, 504:
                guard attempt < maxRetries else {
                    throw response.statusCode == 429 ? RedditError.rateLimited : RedditError.http(response.statusCode)
                }
                let reset = headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }
                    ?? headers.first { $0.key.caseInsensitiveCompare("X-Ratelimit-Reset") == .orderedSame }
                let delay = reset.flatMap { Double($0.value) } ?? backoffBase * pow(2, Double(attempt))
                await limiter.backOff(seconds: delay)
                attempt += 1
                continue
            default:
                throw RedditError.http(response.statusCode)
            }
        }
    }

    private static func headerDictionary(_ response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            out["\(key)"] = "\(value)"
        }
        return out
    }

    // MARK: Mapping entries

    static func post(from entry: AtomFeed.Entry, subreddit: String) -> PostDTO? {
        guard entry.id.hasPrefix("t3_") else { return nil }
        let id = String(entry.id.dropFirst(3))
        let parts = FeedHTML.parts(entry.content)
        let permalink = URLComponents(string: entry.link)?.path ?? "/comments/\(id)/"
        let linked = parts.linkURL.map { $0.hasPrefix("/") ? "https://www.reddit.com" + $0 : $0 }
        let isSelf = linked == nil || URLComponents(string: linked!)?.path == permalink
        let host = linked.flatMap { URL(string: $0)?.host?.lowercased() } ?? ""
        return PostDTO(
            id: id,
            subreddit: subreddit,
            title: entry.title,
            selftext: parts.body,
            author: Self.username(entry.author),
            score: -1,
            numComments: -1,
            createdUTC: (entry.published ?? entry.updated ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970,
            permalink: permalink,
            url: isSelf ? "https://www.reddit.com" + permalink : linked,
            postHint: host == "i.redd.it" || host == "i.imgur.com" ? "image" : nil,
            isSelf: isSelf,
            isGallery: linked?.contains("reddit.com/gallery/") ?? false,
            isVideo: host == "v.redd.it"
        )
    }

    static func comment(from entry: AtomFeed.Entry) -> CommentDTO? {
        guard entry.id.hasPrefix("t1_") else { return nil }
        let body = FeedHTML.parts(entry.content).body
        guard !body.isEmpty else { return nil }
        return CommentDTO(id: String(entry.id.dropFirst(3)), author: username(entry.author), body: body,
                          score: -1, depth: 0, replies: [])
    }

    static func username(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/u/") { return String(trimmed.dropFirst(3)) }
        return trimmed.isEmpty ? "[deleted]" : trimmed
    }
}

// MARK: - Atom

/// The parts of an Atom feed Rounds reads.
struct AtomFeed: Sendable {
    struct Entry: Sendable {
        var id = ""
        var title = ""
        var author = ""
        var content = ""
        var link = ""
        var published: Date?
        var updated: Date?
    }

    var title = ""
    var entries: [Entry] = []

    static func parse(_ data: Data) -> AtomFeed? {
        let delegate = AtomParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawFeed else { return nil }
        return delegate.feed
    }
}

private final class AtomParserDelegate: NSObject, XMLParserDelegate {
    var feed = AtomFeed()
    var sawFeed = false
    private var entry: AtomFeed.Entry?
    private var text = ""
    private var inAuthor = false

    private let dates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "feed": sawFeed = true
        case "entry": entry = AtomFeed.Entry()
        case "author": inAuthor = true
        case "link" where entry != nil:
            if entry?.link.isEmpty ?? false, let href = attributes["href"] { entry?.link = href }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        guard entry != nil else {
            if name == "title", feed.title.isEmpty { feed.title = value }
            return
        }
        switch name {
        case "id": entry?.id = value
        case "title": entry?.title = value
        case "name" where inAuthor: entry?.author = value
        case "author": inAuthor = false
        case "content": entry?.content = text
        case "published": entry?.published = dates.date(from: value)
        case "updated": entry?.updated = dates.date(from: value)
        case "entry":
            if let entry { feed.entries.append(entry) }
            entry = nil
        default: break
        }
    }
}

// MARK: - HTML

/// Turns the HTML Reddit puts in feed entries into the Markdown-ish text Rounds stores for API posts.
enum FeedHTML {
    struct Parts: Equatable {
        /// Post or comment text, with links as `[title](url)` or bare URLs.
        var body: String
        /// Target of the "[link]" anchor in a post entry (the outbound URL, or the permalink for text posts).
        var linkURL: String?
    }

    static func parts(_ html: String) -> Parts {
        var linkURL: String?
        if let match = html.range(of: #"<a href="([^"]*)">\s*\[link\]\s*</a>"#, options: .regularExpression) {
            let anchor = String(html[match])
            if let start = anchor.range(of: "href=\"")?.upperBound, let end = anchor[start...].firstIndex(of: "\"") {
                linkURL = decodeEntities(String(anchor[start..<end]))
            }
        }
        // The text lives in <div class="md">…</div>; link and image posts have none.
        var body = ""
        if let open = html.range(of: #"<div class="md">"#),
           let close = html.range(of: "<!-- SC_ON -->", range: open.upperBound..<html.endIndex)
            ?? html.range(of: "</div>", options: .backwards, range: open.upperBound..<html.endIndex) {
            body = text(String(html[open.upperBound..<close.lowerBound]))
        }
        return Parts(body: body, linkURL: linkURL)
    }

    /// HTML fragment → plain text with Markdown links.
    static func text(_ html: String) -> String {
        var s = html
        // Anchors: keep bare URLs bare, otherwise write [title](url).
        s = replace(#"<a [^>]*href="([^"]*)"[^>]*>(.*?)</a>"#, in: s) { groups in
            let url = decodeEntities(groups[1])
            let title = decodeEntities(strip(groups[2])).trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || title == url || url.hasSuffix(title) { return url }
            return "[\(title)](\(url))"
        }
        s = replace(#"<li[^>]*>"#, in: s) { _ in "\n- " }
        s = replace(#"<br\s*/?>|</(div|h[1-6]|tr)>"#, in: s) { _ in "\n" }
        s = replace(#"</(p|pre|blockquote|table|ul|ol)>"#, in: s) { _ in "\n\n" }
        s = strip(s)
        s = decodeEntities(s)
        // Tidy whitespace: trim lines, at most one blank line in a row.
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for line in lines where !(line.isEmpty && (out.last?.isEmpty ?? true)) {
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func strip(_ html: String) -> String {
        html.replacingOccurrences(of: #"<!--.*?-->|<[^>]+>"#, with: "", options: .regularExpression)
    }

    /// Named entities Reddit uses plus every numeric one.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
        ]
        return replace(#"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);"#, in: s) { groups in
            let name = groups[1]
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? groups[0]
            }
            if name.hasPrefix("#") {
                return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? groups[0]
            }
            return named[name] ?? groups[0]
        }
        .replacingOccurrences(of: "\u{200B}", with: "")
    }

    private static func replace(_ pattern: String, in s: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += transform(groups)
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
