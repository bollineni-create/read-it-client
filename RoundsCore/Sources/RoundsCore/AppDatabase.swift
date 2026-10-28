import Foundation
import GRDB

/// Which slice of the library the thread list shows.
public enum LibraryScope: Hashable, Sendable {
    case all
    case resources
    case saved
    case subreddit(String)
}

public enum ThreadSort: String, CaseIterable, Sendable, Identifiable {
    case relevance, top, discussed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .relevance: "Most relevant"
        case .top: "Top"
        case .discussed: "Most discussed"
        }
    }
}

public struct ThreadQuery: Sendable, Equatable {
    public var scope: LibraryScope
    public var sort: ThreadSort
    public var search: String
    public var hideImageAndMemePosts: Bool
    public var minimumUpvotes: Int
    public var limit: Int

    public init(scope: LibraryScope = .all, sort: ThreadSort = .relevance, search: String = "",
                hideImageAndMemePosts: Bool = false, minimumUpvotes: Int = 0, limit: Int = 500) {
        self.scope = scope
        self.sort = sort
        self.search = search
        self.hideImageAndMemePosts = hideImageAndMemePosts
        self.minimumUpvotes = minimumUpvotes
        self.limit = limit
    }
}

public struct LibraryCounts: Sendable, Equatable {
    public var all = 0
    public var resources = 0
    public var saved = 0
    public var bySubreddit: [String: Int] = [:]

    public init() {}
}

public struct StorageStats: Sendable, Equatable {
    public var threadCount: Int
    public var commentCount: Int
    public var resourceCount: Int
    public var databaseBytes: Int64
    public var indexBytes: Int64?
}

/// SQLite storage through GRDB, with an FTS5 index over threads, comments and resources.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// On-disk database in WAL mode.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(pool)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Rounds", isDirectory: true).appendingPathComponent("rounds.sqlite")
    }

    // MARK: Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "subreddit") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("window", .text).notNull()
                t.column("keywords", .text).notNull()
                t.column("includeKinds", .text).notNull()
                t.column("lastSynced", .datetime)
                t.column("lastError", .text)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "thread") { t in
                t.primaryKey("id", .text)
                t.column("sub", .text).notNull().indexed()
                t.column("subName", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("author", .text).notNull()
                t.column("score", .integer).notNull()
                t.column("numComments", .integer).notNull()
                t.column("createdUTC", .datetime).notNull()
                t.column("permalink", .text).notNull()
                t.column("postURL", .text)
                t.column("kind", .text).notNull()
                t.column("relevance", .double).notNull().defaults(to: 0)
                t.column("why", .text).notNull().defaults(to: "")
                t.column("matchedKeywords", .text).notNull()
                t.column("isSaved", .boolean).notNull().defaults(to: false)
                t.column("savedOnReddit", .boolean).notNull().defaults(to: false)
                t.column("linkCount", .integer).notNull().defaults(to: 0)
                t.column("maxDepth", .integer).notNull().defaults(to: 0)
                t.column("isImageOnly", .boolean).notNull().defaults(to: false)
                t.column("commentsFetchedAt", .datetime)
                t.column("firstSeenAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "thread_relevance", on: "thread", columns: ["sub", "relevance"])
            try db.create(table: "comment") { t in
                t.primaryKey("id", .text)
                t.column("threadId", .text).notNull().indexed().references("thread", onDelete: .cascade)
                t.column("author", .text).notNull()
                t.column("body", .text).notNull()
                t.column("score", .integer).notNull()
                t.column("depth", .integer).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(table: "resource") { t in
                t.primaryKey("id", .text)
                t.column("url", .text).notNull()
                t.column("domain", .text).notNull()
                t.column("title", .text).notNull()
                t.column("threadId", .text).notNull().indexed().references("thread", onDelete: .cascade)
                t.column("sourceCommentId", .text)
            }
            // One row per thread: title, body, every stored comment, and resource titles + domains.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE thread_fts USING fts5(
                    threadId UNINDEXED, title, body, comments, resources,
                    tokenize = 'porter unicode61 remove_diacritics 2'
                )
                """)
        }
        migrator.registerMigration("v2-topRank") { db in
            try db.alter(table: "thread") { t in
                t.add(column: "topRank", .integer)
            }
        }
        return migrator
    }

    // MARK: Subreddits

    public func subreddits() throws -> [Subreddit] {
        try writer.read { db in
            try Subreddit.order(Column("sortIndex"), Column("name").collating(.nocase)).fetchAll(db)
        }
    }

    public func subreddit(id: String) throws -> Subreddit? {
        try writer.read { db in try Subreddit.fetchOne(db, key: id.lowercased()) }
    }

    public func save(_ subreddit: Subreddit) throws {
        try writer.write { db in try subreddit.save(db) }
    }

    /// Inserts default subreddits the first time the app runs.
    public func seedDefaultSubredditsIfEmpty(_ names: [String] = Subreddit.defaultNames) throws {
        try writer.write { db in
            guard try Subreddit.fetchCount(db) == 0 else { return }
            for (i, name) in names.enumerated() {
                try Subreddit(name: name, colorHex: Subreddit.color(forIndex: i), sortIndex: i).insert(db)
            }
        }
    }

    /// Removes a subreddit and its threads, except threads the user saved.
    public func deleteSubreddit(id: String) throws {
        try writer.write { db in
            let key = id.lowercased()
            let doomed = try String.fetchAll(db, sql: "SELECT id FROM thread WHERE sub = ? AND isSaved = 0 AND savedOnReddit = 0", arguments: [key])
            try Self.deleteThreads(db, ids: doomed)
            _ = try Subreddit.deleteOne(db, key: key)
        }
    }

    // MARK: Threads

    public func thread(id: String) throws -> RedditThread? {
        try writer.read { db in try RedditThread.fetchOne(db, key: id) }
    }

    public func threads(ids: [String]) throws -> [RedditThread] {
        try writer.read { db in try RedditThread.fetchAll(db, keys: ids) }
    }

    public func detail(threadID: String) throws -> ThreadDetail? {
        try writer.read { db in
            guard let thread = try RedditThread.fetchOne(db, key: threadID) else { return nil }
            let comments = try Comment.filter(Column("threadId") == threadID).order(Column("position")).fetchAll(db)
            let resources = try Resource.filter(Column("threadId") == threadID).order(Column("rowid")).fetchAll(db)
            return ThreadDetail(thread: thread, comments: comments, resources: resources)
        }
    }

    public func setSaved(threadID: String, _ saved: Bool) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE thread SET isSaved = ? WHERE id = ?", arguments: [saved, threadID])
        }
    }

    /// Thread list for the middle column. Search uses FTS5 with prefix matching on every term.
    public func threads(_ query: ThreadQuery) throws -> [RedditThread] {
        try writer.read { db in
            var sql = "SELECT thread.* FROM thread"
            var arguments: StatementArguments = []
            let match = Self.ftsQuery(query.search)
            if match != nil {
                sql += " JOIN thread_fts ON thread_fts.threadId = thread.id"
            }
            let (whereSQL, whereArgs) = Self.whereClause(query)
            var clauses = [whereSQL]
            arguments += whereArgs
            if let match {
                clauses.append("thread_fts MATCH ?")
                arguments += [match]
            }
            sql += " WHERE " + clauses.joined(separator: " AND ")

            switch query.sort {
            case .relevance:
                sql += match != nil ? " ORDER BY bm25(thread_fts, 0, 10, 4, 1, 2) - thread.relevance / 20.0" : " ORDER BY thread.relevance DESC"
            case .top:
                // Feed threads have no score (-1); their top-listing rank orders them.
                sql += " ORDER BY thread.score DESC, thread.topRank IS NULL, thread.topRank"
            case .discussed:
                sql += " ORDER BY thread.numComments DESC"
            }
            sql += ", thread.createdUTC DESC LIMIT ?"
            arguments += [query.limit]
            return try RedditThread.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    public func counts(hideImageAndMemePosts: Bool, minimumUpvotes: Int) throws -> LibraryCounts {
        try writer.read { db in
            var counts = LibraryCounts()
            func count(_ scope: LibraryScope) throws -> Int {
                var q = ThreadQuery(scope: scope)
                q.hideImageAndMemePosts = hideImageAndMemePosts
                q.minimumUpvotes = minimumUpvotes
                let (w, args) = Self.whereClause(q)
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread WHERE \(w)", arguments: args) ?? 0
            }
            counts.all = try count(.all)
            counts.resources = try count(.resources)
            counts.saved = try count(.saved)

            var q = ThreadQuery(scope: .all)
            q.hideImageAndMemePosts = hideImageAndMemePosts
            q.minimumUpvotes = minimumUpvotes
            let filter = Self.filterClause(q)
            let rows = try Row.fetchAll(db, sql: "SELECT sub, COUNT(*) AS n FROM thread WHERE \(filter.0) GROUP BY sub", arguments: filter.1)
            for row in rows {
                counts.bySubreddit[row["sub"]] = row["n"]
            }
            return counts
        }
    }

    static func whereClause(_ query: ThreadQuery) -> (String, StatementArguments) {
        var clauses: [String] = []
        var args: StatementArguments = []
        switch query.scope {
        case .all:
            clauses.append("(thread.sub IN (SELECT id FROM subreddit WHERE isEnabled = 1) OR thread.isSaved = 1)")
        case .resources:
            clauses.append("thread.kind = 'resource'")
        case .saved:
            clauses.append("thread.isSaved = 1")
        case .subreddit(let id):
            clauses.append("thread.sub = ?")
            args += [id.lowercased()]
        }
        // Per-subreddit "include types".
        if query.scope != .saved {
            clauses.append("""
                (thread.isSaved = 1 OR NOT EXISTS (SELECT 1 FROM subreddit s WHERE s.id = thread.sub
                    AND NOT EXISTS (SELECT 1 FROM json_each(s.includeKinds) WHERE json_each.value = thread.kind)))
                """)
            let filter = filterClause(query)
            clauses.append(filter.0)
            args += filter.1
        }
        return (clauses.joined(separator: " AND "), args)
    }

    /// Filters from Settings. Saved threads are never hidden.
    static func filterClause(_ query: ThreadQuery) -> (String, StatementArguments) {
        var hidden: [String] = []
        var args: StatementArguments = []
        if query.minimumUpvotes > 0 {
            hidden.append("(thread.score >= 0 AND thread.score < ?)")
            args += [query.minimumUpvotes]
        }
        if query.hideImageAndMemePosts {
            hidden.append("thread.isImageOnly = 1")
        }
        guard !hidden.isEmpty else { return ("1", []) }
        return ("(thread.isSaved = 1 OR NOT (\(hidden.joined(separator: " OR "))))", args)
    }

    /// Turns what the user typed into an FTS5 query: every term must match, the last ones as prefixes.
    public static func ftsQuery(_ text: String) -> String? {
        let terms = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
    }

    // MARK: Sync support

    /// Writes a thread with its comments and resources, then refreshes its FTS row.
    public func upsert(thread: RedditThread, comments: [Comment]?, resources: [Resource]?) throws {
        try writer.write { db in
            try Self.upsert(db, thread: thread, comments: comments, resources: resources)
        }
    }

    static func upsert(_ db: Database, thread: RedditThread, comments: [Comment]?, resources: [Resource]?) throws {
        try thread.save(db)
        if let comments {
            try Comment.filter(Column("threadId") == thread.id).deleteAll(db)
            for c in comments { try c.save(db) }
        }
        if let resources {
            try Resource.filter(Column("threadId") == thread.id).deleteAll(db)
            for r in resources { try r.save(db) }
        }
        try refreshFTS(db, threadID: thread.id)
    }

    static func refreshFTS(_ db: Database, threadID: String) throws {
        try db.execute(sql: "DELETE FROM thread_fts WHERE threadId = ?", arguments: [threadID])
        try db.execute(sql: """
            INSERT INTO thread_fts (threadId, title, body, comments, resources)
            SELECT t.id, t.title, t.body,
                   COALESCE((SELECT group_concat(body, char(10)) FROM comment WHERE threadId = t.id), ''),
                   COALESCE((SELECT group_concat(title || ' ' || domain || ' ' || url, char(10)) FROM resource WHERE threadId = t.id), '')
            FROM thread t WHERE t.id = ?
            """, arguments: [threadID])
    }

    static func deleteThreads(_ db: Database, ids: [String]) throws {
        for id in ids {
            try db.execute(sql: "DELETE FROM thread_fts WHERE threadId = ?", arguments: [id])
            _ = try RedditThread.deleteOne(db, key: id)
        }
    }

    /// Threads of a subreddit with their comment bodies, for re-scoring.
    public func scoringRows(subredditID: String) throws -> [(RedditThread, [String])] {
        try writer.read { db in
            let threads = try RedditThread.filter(Column("sub") == subredditID.lowercased()).fetchAll(db)
            return try threads.map { thread in
                let bodies = try String.fetchAll(db, sql: "SELECT body FROM comment WHERE threadId = ? ORDER BY position", arguments: [thread.id])
                return (thread, bodies)
            }
        }
    }

    /// Forgets top-listing ranks before a sync records the current ones.
    public func clearTopRanks(subredditID: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE thread SET topRank = NULL WHERE sub = ?", arguments: [subredditID.lowercased()])
        }
    }

    public func updateScores(_ updates: [(id: String, relevance: Double, why: String, matched: [String])]) throws {
        try writer.write { db in
            for u in updates {
                let matched = String(decoding: try JSONEncoder().encode(u.matched), as: UTF8.self)
                try db.execute(
                    sql: "UPDATE thread SET relevance = ?, why = ?, matchedKeywords = ? WHERE id = ?",
                    arguments: [u.relevance, u.why, matched, u.id]
                )
            }
        }
    }

    /// Keeps the `limit` most relevant threads of a subreddit plus anything saved. Returns removed ids.
    @discardableResult
    public func prune(subredditID: String, keep limit: Int) throws -> [String] {
        try writer.write { db in
            let doomed = try String.fetchAll(db, sql: """
                SELECT id FROM thread WHERE sub = ? AND isSaved = 0 AND savedOnReddit = 0
                ORDER BY relevance DESC, score DESC LIMIT -1 OFFSET ?
                """, arguments: [subredditID.lowercased(), limit])
            try Self.deleteThreads(db, ids: doomed)
            return doomed
        }
    }

    public func subredditStats(subredditID: String) throws -> SubredditStats {
        try writer.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT MAX(score) AS s, MAX(numComments) AS c, MAX(topRank) AS r FROM thread WHERE sub = ?", arguments: [subredditID.lowercased()])
            return SubredditStats(maxScore: row?["s"] ?? 0, maxComments: row?["c"] ?? 0, maxRank: row?["r"] ?? 0)
        }
    }

    // MARK: Maintenance

    public func rebuildSearchIndex() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM thread_fts")
            let ids = try String.fetchAll(db, sql: "SELECT id FROM thread")
            for id in ids { try Self.refreshFTS(db, threadID: id) }
            try db.execute(sql: "INSERT INTO thread_fts(thread_fts) VALUES('optimize')")
        }
    }

    /// Number of rows in the FTS index (one per thread).
    public func searchIndexRowCount() throws -> Int {
        try writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread_fts") ?? 0 }
    }

    /// Empties the FTS index without touching threads (used to exercise Rebuild Index).
    func dropSearchIndexRows() throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM thread_fts") }
    }

    public func clearAllData() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM thread_fts")
            try db.execute(sql: "DELETE FROM resource")
            try db.execute(sql: "DELETE FROM comment")
            try db.execute(sql: "DELETE FROM thread")
            try db.execute(sql: "UPDATE subreddit SET lastSynced = NULL, lastError = NULL")
        }
        try? writer.vacuum()
    }

    public func storageStats() throws -> StorageStats {
        try writer.read { db in
            let threads = try RedditThread.fetchCount(db)
            let comments = try Comment.fetchCount(db)
            let resources = try Resource.fetchCount(db)
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
            let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            // dbstat is optional in SQLite builds; fall back to nil when missing.
            let index = try? Int64.fetchOne(db, sql: "SELECT SUM(pgsize) FROM dbstat WHERE name LIKE 'thread_fts%'")
            return StorageStats(threadCount: threads, commentCount: comments, resourceCount: resources,
                                databaseBytes: pageSize * pages, indexBytes: index ?? nil)
        }
    }

    /// Threads for Spotlight indexing.
    public func allThreads() throws -> [RedditThread] {
        try writer.read { db in try RedditThread.fetchAll(db) }
    }
}
