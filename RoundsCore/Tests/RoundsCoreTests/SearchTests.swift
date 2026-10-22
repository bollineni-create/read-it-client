import XCTest
@testable import RoundsCore

final class SearchTests: XCTestCase {
    var db: AppDatabase!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        try db.save(Subreddit(name: "mdphd", colorHex: "#0B6E69"))
        try db.save(Subreddit(name: "medicalschool", colorHex: "#D9822B"))

        try db.upsert(
            thread: RedditThread(id: "t1", sub: "mdphd", subName: "mdphd", title: "MSTP interview season",
                                 body: "Share your interviewing experiences", author: "a", score: 500, numComments: 90,
                                 createdUTC: Date(), permalink: "/r/mdphd/comments/t1/", relevance: 80),
            comments: [Comment(id: "c1", threadId: "t1", author: "b", body: "WashU asked about my thesis", score: 10, depth: 0, position: 0)],
            resources: [Resource(url: "https://docs.google.com/spreadsheets/d/x", domain: "docs.google.com", title: "Interview tracker", threadId: "t1", sourceCommentId: nil)]
        )
        try db.upsert(
            thread: RedditThread(id: "t2", sub: "medicalschool", subName: "medicalschool", title: "Pharmacology resources",
                                 body: "Sketchy versus Pixorize", author: "a", score: 300, numComments: 40,
                                 createdUTC: Date(), permalink: "/r/medicalschool/comments/t2/", kind: .resource, relevance: 60),
            comments: [Comment(id: "c2", threadId: "t2", author: "b", body: "Anki decks are the way", score: 4, depth: 0, position: 0)],
            resources: [Resource(url: "https://ankiweb.net/shared/info/1", domain: "ankiweb.net", title: "AnKing", threadId: "t2", sourceCommentId: "c2")]
        )
        try db.upsert(
            thread: RedditThread(id: "t3", sub: "medicalschool", subName: "medicalschool", title: "Funny meme",
                                 body: "", author: "a", score: 5, numComments: 2,
                                 createdUTC: Date(), permalink: "/r/medicalschool/comments/t3/", relevance: 10, isImageOnly: true),
            comments: [], resources: []
        )
    }

    func search(_ text: String, scope: LibraryScope = .all) throws -> [String] {
        try db.threads(ThreadQuery(scope: scope, search: text)).map(\.id)
    }

    func testMatchesTitleBodyCommentsAndResources() throws {
        XCTAssertEqual(try search("MSTP"), ["t1"])
        XCTAssertEqual(try search("pixorize"), ["t2"], "body")
        XCTAssertEqual(try search("thesis"), ["t1"], "comment body")
        XCTAssertEqual(try search("tracker"), ["t1"], "resource title")
        XCTAssertEqual(try search("ankiweb"), ["t2"], "resource domain")
    }

    func testPrefixAndStemmingAndMultipleTerms() throws {
        XCTAssertEqual(try search("interv"), ["t1"], "prefix match while typing")
        XCTAssertEqual(try search("interviews"), ["t1"], "porter stemming")
        XCTAssertEqual(try search("anki sketchy"), ["t2"])
        XCTAssertEqual(try search("anki thesis"), [], "all terms must match")
    }

    func testQuerySanitizing() throws {
        XCTAssertNil(AppDatabase.ftsQuery("   "))
        XCTAssertEqual(AppDatabase.ftsQuery("step-1 \"OR\""), "\"step\"* \"1\"* \"OR\"*")
        XCTAssertNoThrow(try search("NEAR( AND * ^ \""))
    }

    func testSearchRespectsScopeAndFilters() throws {
        XCTAssertEqual(try search("anki", scope: .subreddit("mdphd")), [])
        XCTAssertEqual(try search("anki", scope: .resources), ["t2"])
        let filtered = try db.threads(ThreadQuery(search: "meme", hideImageAndMemePosts: true))
        XCTAssertTrue(filtered.isEmpty)
        let lowVotes = try db.threads(ThreadQuery(minimumUpvotes: 25)).map(\.id)
        XCTAssertEqual(lowVotes, ["t1", "t2"])
    }

    func testSavedThreadsIgnoreFilters() throws {
        try db.setSaved(threadID: "t3", true)
        let all = try db.threads(ThreadQuery(hideImageAndMemePosts: true, minimumUpvotes: 25)).map(\.id)
        XCTAssertTrue(all.contains("t3"))
        XCTAssertEqual(try db.threads(ThreadQuery(scope: .saved)).map(\.id), ["t3"])
    }

    func testSortOrders() throws {
        XCTAssertEqual(try db.threads(ThreadQuery(sort: .relevance)).map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(try db.threads(ThreadQuery(sort: .discussed)).map(\.id), ["t1", "t2", "t3"])
        try db.upsert(thread: RedditThread(id: "t4", sub: "mdphd", subName: "mdphd", title: "x", body: "", author: "a",
                                           score: 9999, numComments: 0, createdUTC: Date(), permalink: "/x", relevance: 1),
                      comments: nil, resources: nil)
        XCTAssertEqual(try db.threads(ThreadQuery(sort: .top)).first?.id, "t4")
    }

    func testIndexStaysInSyncOnUpdateAndDelete() throws {
        var t1 = try XCTUnwrap(db.thread(id: "t1"))
        t1.title = "Residency applications"
        try db.upsert(thread: t1, comments: nil, resources: nil)
        XCTAssertEqual(try search("residency"), ["t1"])
        XCTAssertEqual(try search("thesis"), ["t1"], "comments kept when not replaced")

        try db.deleteSubreddit(id: "mdphd")
        XCTAssertEqual(try search("residency"), [])
        XCTAssertEqual(try db.searchIndexRowCount(), 2)
    }

    func testRebuildIndex() throws {
        try db.dropSearchIndexRows()
        XCTAssertEqual(try search("MSTP"), [])
        try db.rebuildSearchIndex()
        XCTAssertEqual(try search("MSTP"), ["t1"])
    }

    func testCounts() throws {
        let counts = try db.counts(hideImageAndMemePosts: true, minimumUpvotes: 25)
        XCTAssertEqual(counts.all, 2)
        XCTAssertEqual(counts.resources, 1)
        XCTAssertEqual(counts.saved, 0)
        XCTAssertEqual(counts.bySubreddit["medicalschool"], 1)
    }

    func testIncludeKindsFilter() throws {
        var sub = try XCTUnwrap(db.subreddit(id: "medicalschool"))
        sub.includeKinds = [.discussion, .question]
        try db.save(sub)
        XCTAssertEqual(try db.threads(ThreadQuery(scope: .subreddit("medicalschool"))).map(\.id), ["t3"])
    }

    func testClearAllData() throws {
        try db.clearAllData()
        XCTAssertEqual(try db.storageStats().threadCount, 0)
        XCTAssertEqual(try search("MSTP"), [])
        XCTAssertEqual(try db.subreddits().count, 2, "subreddit list survives")
    }
}
