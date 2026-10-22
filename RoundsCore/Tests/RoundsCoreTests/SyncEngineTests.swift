import XCTest
@testable import RoundsCore

final class SyncEngineTests: XCTestCase {
    var db: AppDatabase!
    var transport: MockTransport!
    var settings = AppSettings()

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        try db.save(Subreddit(name: "mdphd", colorHex: "#0B6E69", keywords: ["thesis"]))
        transport = MockTransport()
        transport.on("/r/mdphd/top", body: Fixtures.mdphdTop)
        transport.on("/r/mdphd/hot", body: Fixtures.mdphdHot)
        transport.on("/comments/a1", body: Fixtures.a1Comments)
        transport.on("/comments/a2", body: Fixtures.simpleComments(postID: "a2", title: "How do I balance research and Step 1 studying?", score: 300, comments: 80))
        transport.on("/comments/a4", body: Fixtures.simpleComments(postID: "a4", title: "Reflections after my first year", score: 40, comments: 12))
        transport.on("/comments/a6", body: Fixtures.simpleComments(postID: "a6", title: "Anki deck for biochem", score: 60, comments: 9,
                                                                    selftext: "Here it is: https://ankiweb.net/shared/info/12345 enjoy!"))
        settings.boostKeywords = ["MSTP", "interviews"]
        settings.minimumUpvotes = 25
    }

    func makeEngine() -> SyncEngine {
        let settings = self.settings
        return SyncEngine(db: db, api: makeClient(transport), settings: { settings })
    }

    func testFirstSyncStoresScoresAndClassifies() async throws {
        let report = await makeEngine().sync()
        XCTAssertEqual(report.syncedSubreddits, ["mdphd"])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(Set(report.newThreadIDs), ["a1", "a2", "a3", "a4", "a5", "a6"])
        XCTAssertEqual(report.keywordMatches.map(\.id), ["a1"])

        let a1 = try XCTUnwrap(db.detail(threadID: "a1"))
        XCTAssertEqual(a1.thread.kind, .resource)
        XCTAssertEqual(a1.comments.map(\.id), ["c1", "c2", "c3", "c4"])
        XCTAssertEqual(a1.thread.maxDepth, 2)
        XCTAssertEqual(a1.resources.map(\.url), [
            "https://docs.google.com/spreadsheets/d/abc123/edit?usp=sharing",
            "https://example.com/notes.pdf",
            "https://example.org/guide",
        ])
        XCTAssertEqual(a1.resources[1].sourceCommentId, "c1")
        XCTAssertEqual(a1.thread.linkCount, 3)
        XCTAssertEqual(a1.thread.matchedKeywords, ["MSTP", "interviews"])
        XCTAssertTrue(a1.thread.why.contains("matches: MSTP, interviews"), a1.thread.why)
        XCTAssertGreaterThan(a1.thread.relevance, 0)
        XCTAssertLessThanOrEqual(a1.thread.relevance, 100)

        XCTAssertEqual(try db.thread(id: "a2")?.kind, .question)
        XCTAssertEqual(try db.thread(id: "a4")?.kind, .discussion)
        XCTAssertEqual(try db.thread(id: "a6")?.kind, .resource)
        XCTAssertEqual(try db.thread(id: "a3")?.isImageOnly, true)
        XCTAssertNil(try db.thread(id: "pin"), "stickied hot posts are skipped")

        // Image posts and low-score posts don't cost comment requests.
        let commentRequests = transport.requestedPaths.filter { $0.hasPrefix("/comments/") }
        XCTAssertEqual(Set(commentRequests), ["/comments/a1", "/comments/a2", "/comments/a4", "/comments/a6"])

        let sub = try XCTUnwrap(db.subreddit(id: "mdphd"))
        XCTAssertNotNil(sub.lastSynced)
        XCTAssertNil(sub.lastError)

        // Searchable offline right away.
        XCTAssertEqual(try db.threads(ThreadQuery(search: "WashU")).map(\.id), ["a1"])
    }

    func testSecondSyncIsIncremental() async throws {
        let engine = makeEngine()
        await engine.sync()
        let before = transport.requestedPaths.count
        await engine.sync()
        let after = transport.requestedPaths.filter { $0.hasPrefix("/comments/") }.count
        XCTAssertEqual(after, 4, "unchanged threads don't refetch comments")
        XCTAssertEqual(transport.requestedPaths.count - before, 2, "only top + hot")
    }

    func testRescoresWhenCountsChangeAndKeepsSavedThreads() async throws {
        let engine = makeEngine()
        await engine.sync()
        try db.setSaved(threadID: "a4", true)
        let oldRelevance = try XCTUnwrap(db.thread(id: "a2")).relevance

        // Next pass: a2 blew up, a4 dropped out of the listings entirely.
        let transport2 = MockTransport()
        transport2.on("/r/mdphd/top", body: Fixtures.listing([
            Fixtures.post(id: "a1", title: "MSTP interviews megathread: share your experiences", score: 900, comments: 240),
            Fixtures.post(id: "a2", title: "How do I balance research and Step 1 studying?", score: 2000, comments: 600),
        ]))
        transport2.on("/r/mdphd/hot", body: Fixtures.listing([]))
        transport2.on("/comments/a2", body: Fixtures.simpleComments(postID: "a2", title: "How do I balance research and Step 1 studying?", score: 2000, comments: 600))
        var smallSettings = settings
        smallSettings.threadsPerSubreddit = 2
        let small = smallSettings
        let engine2 = SyncEngine(db: db, api: makeClient(transport2), settings: { small })
        await engine2.sync()

        let a2 = try XCTUnwrap(db.thread(id: "a2"))
        XCTAssertEqual(a2.score, 2000)
        XCTAssertGreaterThan(a2.relevance, oldRelevance)
        XCTAssertEqual(transport2.requestedPaths.filter { $0.hasPrefix("/comments/") }, ["/comments/a2"])

        let remaining = try Set(db.threads(ThreadQuery(scope: .subreddit("mdphd"), limit: 100)).map(\.id))
        XCTAssertTrue(remaining.contains("a4"), "saved thread survives pruning and dropping out of the top list")
        XCTAssertEqual(try db.scoringRows(subredditID: "mdphd").filter { !$0.0.isSaved }.count, 2, "pruned to the keep limit")
        XCTAssertNotNil(try db.detail(threadID: "a1")?.resources.first, "kept threads keep their stored resources")
    }

    func testFailureIsRecordedPerSubreddit() async throws {
        try db.save(Subreddit(name: "broken", colorHex: "#000000"))
        transport.on("/r/broken/top", status: 403, body: "{}")
        let report = await makeEngine().sync()
        XCTAssertEqual(report.syncedSubreddits, ["mdphd"])
        XCTAssertNotNil(report.failures["broken"])
        XCTAssertNotNil(try db.subreddit(id: "broken")?.lastError)
    }

    func testConcurrentCallsShareOnePass() async throws {
        let engine = makeEngine()
        async let first = engine.sync(["mdphd"])
        async let second = engine.sync(["mdphd"])
        let (r1, r2) = await (first, second)
        XCTAssertFalse(r1.syncedSubreddits.isEmpty && r2.syncedSubreddits.isEmpty)
        let topCalls = transport.requestedPaths.filter { $0 == "/r/mdphd/top" }.count
        XCTAssertLessThanOrEqual(topCalls, 2)
    }

    func testImportSaved() async throws {
        transport.on("/user/tester/saved", body: Fixtures.listing([
            Fixtures.post(id: "s1", sub: "premed", title: "My school list spreadsheet", selftext: "https://docs.google.com/spreadsheets/d/zzz", score: 12, comments: 3),
        ]))
        transport.on("/comments/s1", body: Fixtures.simpleComments(postID: "s1", title: "My school list spreadsheet", score: 12, comments: 3))
        let count = try await makeEngine().importSaved(username: "tester")
        XCTAssertEqual(count, 1)
        let s1 = try XCTUnwrap(db.thread(id: "s1"))
        XCTAssertTrue(s1.isSaved)
        XCTAssertTrue(s1.savedOnReddit)
        XCTAssertEqual(s1.sub, "premed")
        XCTAssertEqual(try db.threads(ThreadQuery(scope: .saved, minimumUpvotes: 25)).map(\.id), ["s1"])
    }
}
