import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RoundsCore

/// Atom feeds trimmed from real `www.reddit.com/…/.rss` responses.
enum FeedFixtures {
    static func entry(id: String, sub: String = "mdphd", title: String, author: String = "someone", content: String,
                      published: String = "2026-10-22T22:33:31+00:00") -> String {
        """
        <entry><author><name>/u/\(author)</name><uri>https://www.reddit.com/user/\(author)</uri></author>\
        <category term="\(sub)" label="r/\(sub)"/><content type="html">\(content)</content><id>t3_\(id)</id>\
        <link href="https://www.reddit.com/r/\(sub)/comments/\(id)/slug/" /><updated>\(published)</updated>\
        <published>\(published)</published><title>\(title)</title></entry>
        """
    }

    static func footer(id: String, sub: String = "mdphd", link: String? = nil, author: String = "someone") -> String {
        let permalink = "https://www.reddit.com/r/\(sub)/comments/\(id)/slug/"
        return " &amp;#32; submitted by &amp;#32; &lt;a href=&quot;https://www.reddit.com/user/\(author)&quot;&gt; /u/\(author) &lt;/a&gt; &lt;br/&gt; "
            + "&lt;span&gt;&lt;a href=&quot;\(link ?? permalink)&quot;&gt;[link]&lt;/a&gt;&lt;/span&gt; &amp;#32; "
            + "&lt;span&gt;&lt;a href=&quot;\(permalink)&quot;&gt;[comments]&lt;/a&gt;&lt;/span&gt;"
    }

    static func md(_ html: String) -> String {
        "&lt;!-- SC_OFF --&gt;&lt;div class=&quot;md&quot;&gt;\(html)&lt;/div&gt;&lt;!-- SC_ON --&gt;"
    }

    static func feed(title: String = "top scoring links : mdphd", _ entries: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?><feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">\
        <category term="mdphd" label="r/mdphd"/><updated>2026-10-28T21:25:08+00:00</updated><id>/r/mdphd/top/.rss</id>\
        <title>\(title)</title>\(entries.joined())</feed>
        """
    }

    static let top = feed([
        entry(id: "f1", title: "MSTP interviews: what I wish I knew",
              content: md("&lt;p&gt;Here&amp;#39;s my tracker: &lt;a href=&quot;https://docs.google.com/spreadsheets/d/abc123/edit?usp=sharing&amp;amp;utm_source=reddit&quot;&gt;Interview tracker&lt;/a&gt;&lt;/p&gt; &lt;p&gt;Good luck &amp;amp; have fun.&lt;/p&gt; ") + footer(id: "f1")),
        entry(id: "f2", title: "How do I balance research and Step 1?",
              content: md("&lt;p&gt;Asking for a friend.&lt;/p&gt; ") + footer(id: "f2")),
        entry(id: "f3", title: "Lab life", content: "&lt;table&gt; &lt;tr&gt;&lt;td&gt; &lt;img src=&quot;https://preview.redd.it/x.png&quot; /&gt; &lt;/td&gt;&lt;td&gt;"
              + footer(id: "f3", link: "https://i.redd.it/xyz.png") + "&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;"),
        entry(id: "f4", title: "Great review article", content: footer(id: "f4", link: "https://www.nature.com/articles/abc")),
    ])

    static let hot = feed(title: "hot : mdphd", [
        entry(id: "f2", title: "How do I balance research and Step 1?", content: md("&lt;p&gt;Asking for a friend.&lt;/p&gt; ") + footer(id: "f2")),
        entry(id: "f5", title: "Anki deck for biochem",
              content: md("&lt;p&gt;Here it is: &lt;a href=&quot;https://ankiweb.net/shared/info/12345&quot;&gt;https://ankiweb.net/shared/info/12345&lt;/a&gt;&lt;/p&gt; ") + footer(id: "f5")),
    ])

    static func comment(id: String, author: String, html: String) -> String {
        """
        <entry><author><name>/u/\(author)</name></author><category term="mdphd" label="r/mdphd" />\
        <content type="html">\(md(html))</content><id>t1_\(id)</id>\
        <link href="https://www.reddit.com/r/mdphd/comments/f1/slug/\(id)/"/><updated>2026-10-27T16:29:34+00:00</updated>\
        <title>/u/\(author) on a thread</title></entry>
        """
    }

    static func thread(postID: String, comments: [String]) -> String {
        feed(title: "a thread", [entry(id: postID, title: "post", content: md("&lt;p&gt;Body&lt;/p&gt;") + footer(id: postID))] + comments)
    }

    static let f1Thread = thread(postID: "f1", comments: [
        comment(id: "c1", author: "alpha", html: "&lt;p&gt;My notes: &lt;a href=&quot;https://example.com/notes.pdf&quot;&gt;https://example.com/notes.pdf&lt;/a&gt;&lt;/p&gt;"),
        comment(id: "c2", author: "beta", html: "&lt;p&gt;Where are you going?&lt;/p&gt;"),
    ])
}

/// Serves one canned body, reporting `finalURL` as where the request ended up (URLSession follows redirects).
private struct RedirectingTransport: HTTPTransport {
    var finalURL: URL
    var body: String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}

func makeFeedClient(_ transport: HTTPTransport) -> RedditFeedClient {
    RedditFeedClient(
        transport: transport,
        limiter: RateLimiter(minimumInterval: 0, sleeper: { _ in }),
        userAgent: { "macos:com.naren.rounds:v1.0 (by /u/tester)" },
        backoffBase: 0
    )
}

final class FeedClientTests: XCTestCase {
    func testParsesTopFeed() async throws {
        let transport = MockTransport()
        transport.on("/r/mdphd/top/.rss", body: FeedFixtures.top)
        let listing = try await makeFeedClient(transport).top(subreddit: "mdphd", window: .month, limit: 250, after: nil)
        let posts = listing.children.compactMap(\.data)

        XCTAssertNil(listing.after)
        XCTAssertEqual(posts.map(\.id), ["f1", "f2", "f3", "f4"])
        let f1 = posts[0]
        XCTAssertEqual(f1.subreddit, "mdphd")
        XCTAssertEqual(f1.author, "someone")
        XCTAssertEqual(f1.score, -1)
        XCTAssertEqual(f1.numComments, -1)
        XCTAssertEqual(f1.permalink, "/r/mdphd/comments/f1/slug/")
        XCTAssertTrue(f1.isSelf)
        XCTAssertNil(f1.externalURL)
        XCTAssertEqual(f1.selftext, """
            Here's my tracker: [Interview tracker](https://docs.google.com/spreadsheets/d/abc123/edit?usp=sharing&utm_source=reddit)

            Good luck & have fun.
            """)
        XCTAssertEqual(f1.createdUTC, 1792708411)

        XCTAssertTrue(posts[2].isImageOrMeme, "image posts with no text")
        XCTAssertEqual(posts[3].externalURL, "https://www.nature.com/articles/abc")
        XCTAssertFalse(posts[3].isImageOrMeme)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.host, "www.reddit.com")
        XCTAssertTrue(request.url?.query?.contains("t=month") ?? false)
        XCTAssertTrue(request.url?.query?.contains("limit=100") ?? false)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "macos:com.naren.rounds:v1.0 (by /u/tester)")
    }

    func testParsesThreadFeedAsFlatComments() async throws {
        let transport = MockTransport()
        transport.on("/comments/f1/.rss", body: FeedFixtures.f1Thread)
        let response = try await makeFeedClient(transport).comments(threadID: "f1", limit: 20)
        XCTAssertNil(response.post)
        XCTAssertEqual(response.comments.map(\.id), ["c1", "c2"])
        XCTAssertEqual(response.comments.map(\.author), ["alpha", "beta"])
        XCTAssertEqual(response.comments[0].body, "My notes: https://example.com/notes.pdf")
        XCTAssertEqual(response.comments.map(\.depth), [0, 0])
        XCTAssertEqual(response.comments.map(\.score), [-1, -1])
        XCTAssertTrue(transport.requests[0].url!.query!.contains("sort=top"))
    }

    func testAboutChecksTheSubredditFeed() async throws {
        let transport = MockTransport()
        transport.on("/r/MCAT/.rss", body: FeedFixtures.feed(title: "MCAT prep", []))
        let about = try await makeFeedClient(transport).about(subreddit: "MCAT")
        XCTAssertEqual(about.displayName, "MCAT")
        XCTAssertEqual(about.publicDescription, "MCAT prep")
    }

    func testMissingSubredditRedirectsToSearch() async {
        let transport = RedirectingTransport(finalURL: URL(string: "https://www.reddit.com/subreddits/search.rss?q=nope")!,
                                             body: FeedFixtures.feed([]))
        do {
            _ = try await makeFeedClient(transport).about(subreddit: "nope")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RedditError, .subredditNotFound("nope"))
        }
    }

    func testPrivateSubreddit() async {
        let transport = MockTransport()
        transport.on("/r/secret/.rss", status: 403, body: "")
        do {
            _ = try await makeFeedClient(transport).about(subreddit: "secret")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RedditError, .subredditPrivate("secret"))
        }
    }

    func testWaitsOutRateLimit() async throws {
        let transport = MockTransport()
        transport.on("/r/mdphd/hot/.rss", status: 429, body: "", headers: ["X-Ratelimit-Reset": "0"])
        transport.on("/r/mdphd/hot/.rss", body: FeedFixtures.hot)
        let listing = try await makeFeedClient(transport).hot(subreddit: "mdphd", limit: 50)
        XCTAssertEqual(listing.children.count, 2)
        XCTAssertEqual(transport.requestedPaths.count, 2)
    }

    func testSavedImportNeedsAPIAccess() async {
        do {
            _ = try await makeFeedClient(MockTransport()).saved(username: "me", after: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RedditError, .needsAPIAccess)
        }
    }

    func testHTMLToText() {
        XCTAssertEqual(FeedHTML.text("<p>One</p> <ul><li>a</li><li>b</li></ul><p>Two &#39;quoted&#39;</p>"),
                       "One\n\n- a\n- b\n\nTwo 'quoted'")
        XCTAssertEqual(FeedHTML.decodeEntities("caf&#xE9; &#8212; &lt;tag&gt; &bogus;"), "café — <tag> &bogus;")
        XCTAssertEqual(FeedHTML.text(#"see <a href="https://a.com/x">https://a.com/x</a> and <a href="https://b.com">B &amp; co</a>"#),
                       "see https://a.com/x and [B & co](https://b.com)")
    }

    func testSourceSwitchesOnClientID() async throws {
        let oauth = MockTransport()
        oauth.on("/r/mdphd/hot", body: Fixtures.mdphdHot)
        let feeds = MockTransport()
        feeds.on("/r/mdphd/hot/.rss", body: FeedFixtures.hot)
        let box = Flag()
        let source = RedditSource(oauth: makeClient(oauth), feeds: makeFeedClient(feeds), useOAuth: { box.value })

        XCTAssertEqual(source.commentFetchesPerPass, 30)
        _ = try await source.hot(subreddit: "mdphd", limit: 50)
        XCTAssertEqual(feeds.requestedPaths, ["/r/mdphd/hot/.rss"])
        box.value = true
        XCTAssertNil(source.commentFetchesPerPass)
        _ = try await source.hot(subreddit: "mdphd", limit: 50)
        XCTAssertEqual(oauth.requestedPaths, ["/r/mdphd/hot"])
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var current = false
    var value: Bool {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

final class FeedSyncTests: XCTestCase {
    var db: AppDatabase!
    var transport: MockTransport!
    var settings = AppSettings()

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        try db.save(Subreddit(name: "mdphd", colorHex: "#0B6E69"))
        transport = MockTransport()
        transport.on("/r/mdphd/top/.rss", body: FeedFixtures.top)
        transport.on("/r/mdphd/hot/.rss", body: FeedFixtures.hot)
        transport.on("/comments/f1/.rss", body: FeedFixtures.f1Thread)
        for id in ["f2", "f4", "f5"] {
            transport.on("/comments/\(id)/.rss", body: FeedFixtures.thread(postID: id, comments: [
                FeedFixtures.comment(id: "\(id)c", author: "gamma", html: "&lt;p&gt;Nice&lt;/p&gt;"),
            ]))
        }
        settings.boostKeywords = ["MSTP"]
        settings.minimumUpvotes = 25
    }

    func makeEngine() -> SyncEngine {
        let settings = self.settings
        return SyncEngine(db: db, api: makeFeedClient(transport), settings: { settings })
    }

    func testSyncWithoutScoresRanksByTopListing() async throws {
        let report = await makeEngine().sync()
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertEqual(Set(report.newThreadIDs), ["f1", "f2", "f3", "f4", "f5"])
        // The upvote filter can't apply without scores, so keyword matches still notify.
        XCTAssertEqual(report.keywordMatches.map(\.id), ["f1"])

        let f1 = try XCTUnwrap(db.detail(threadID: "f1"))
        XCTAssertEqual(f1.thread.score, -1)
        XCTAssertFalse(f1.thread.hasScore)
        XCTAssertEqual(f1.thread.topRank, 1)
        XCTAssertEqual(f1.thread.numComments, 2, "counts the comments the feed returned")
        XCTAssertEqual(f1.thread.kind, .resource)
        XCTAssertEqual(f1.comments.map(\.id), ["c1", "c2"])
        XCTAssertEqual(f1.resources.map(\.url), [
            "https://docs.google.com/spreadsheets/d/abc123/edit?usp=sharing",
            "https://example.com/notes.pdf",
        ])
        XCTAssertTrue(f1.thread.why.hasPrefix("Top post in r/mdphd this month"), f1.thread.why)

        XCTAssertEqual(try db.thread(id: "f4")?.topRank, 4)
        XCTAssertNil(try db.thread(id: "f5")?.topRank, "hot-only threads have no rank")
        XCTAssertGreaterThan(try XCTUnwrap(db.thread(id: "f1")).relevance, try XCTUnwrap(db.thread(id: "f2")).relevance)

        // Unknown scores aren't hidden by the upvote filter.
        let visible = try db.threads(ThreadQuery(scope: .all, sort: .top, minimumUpvotes: 25))
        XCTAssertEqual(visible.map(\.id), ["f1", "f2", "f3", "f4", "f5"])

        // The image post doesn't cost a comment request; ranked threads go first.
        let commentRequests = transport.requestedPaths.filter { $0.hasPrefix("/comments/") }
        XCTAssertEqual(commentRequests, ["/comments/f1/.rss", "/comments/f2/.rss", "/comments/f4/.rss", "/comments/f5/.rss"])
    }

    func testCommentFetchesAreCappedAndFilledInLater() async throws {
        // Build a top feed longer than the per-pass cap.
        let entries = (1...35).map { i in
            FeedFixtures.entry(id: "p\(i)", title: "Thread \(i)", content: FeedFixtures.md("&lt;p&gt;Text \(i)&lt;/p&gt;") + FeedFixtures.footer(id: "p\(i)"))
        }
        transport = MockTransport()
        transport.on("/r/mdphd/top/.rss", body: FeedFixtures.feed(entries))
        transport.on("/r/mdphd/hot/.rss", body: FeedFixtures.feed([]))
        for i in 1...35 {
            transport.on("/comments/p\(i)/.rss", body: FeedFixtures.thread(postID: "p\(i)", comments: []))
        }

        let engine = makeEngine()
        await engine.sync()
        XCTAssertEqual(try db.allThreads().count, 35, "every post is stored on the first pass")
        let first = transport.requestedPaths.filter { $0.hasPrefix("/comments/") }
        XCTAssertEqual(first.count, 30)
        XCTAssertEqual(first.first, "/comments/p1/.rss")
        XCTAssertNil(try db.thread(id: "p31")?.commentsFetchedAt)

        await engine.sync()
        let second = transport.requestedPaths.filter { $0.hasPrefix("/comments/") }.dropFirst(30)
        XCTAssertEqual(Array(second), (31...35).map { "/comments/p\($0)/.rss" }, "the next pass fills in the rest, and nothing is refetched")
    }
}
