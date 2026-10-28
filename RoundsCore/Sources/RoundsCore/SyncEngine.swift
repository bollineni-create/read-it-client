import Foundation

public enum SyncEvent: Sendable {
    case started(subredditID: String)
    case progress(subredditID: String, completed: Int, total: Int)
    case finished(subredditID: String, newThreads: Int)
    case failed(subredditID: String, message: String)
    case idle
}

public struct SyncReport: Sendable {
    public var syncedSubreddits: [String] = []
    public var failures: [String: String] = [:]
    /// Threads seen for the first time in this run.
    public var newThreadIDs: [String] = []
    /// New threads that match a global boost keyword (drives notifications).
    public var keywordMatches: [RedditThread] = []

    public init() {}
}

/// Incremental syncer. One pass per subreddit:
/// 1. fetch `/top?t=window` (paginated up to the keep limit) and `/hot`;
/// 2. upsert threads by id, then fetch comments only for new threads or ones whose comment count changed
///    (capped per pass when the API asks for it, as the anonymous feeds do);
/// 3. re-score the subreddit; 4. prune beyond the keep limit (saved threads are always kept).
public actor SyncEngine {
    private let db: AppDatabase
    private let api: RedditAPI
    private let settings: @Sendable () async -> AppSettings
    private var eventHandler: (@Sendable (SyncEvent) -> Void)?

    private var pending: [(id: String, full: Bool)] = []
    private var loop: Task<SyncReport, Never>?
    private var accumulated = SyncReport()

    public init(db: AppDatabase, api: RedditAPI, settings: @escaping @Sendable () async -> AppSettings) {
        self.db = db
        self.api = api
        self.settings = settings
    }

    public func setEventHandler(_ handler: @escaping @Sendable (SyncEvent) -> Void) {
        eventHandler = handler
    }

    public var isSyncing: Bool { loop != nil }

    /// Queues subreddits (all enabled ones when `ids` is nil) and waits until the queue drains.
    /// Calls made while a pass is running join that pass.
    @discardableResult
    public func sync(_ ids: [String]? = nil, full: Bool = false) async -> SyncReport {
        let targets: [String]
        if let ids {
            targets = ids.map { $0.lowercased() }
        } else {
            targets = ((try? db.subreddits()) ?? []).filter(\.isEnabled).map(\.id)
        }
        for id in targets where !pending.contains(where: { $0.id == id }) {
            pending.append((id, full))
        }
        if let loop { return await loop.value }
        let task = Task { await self.drain() }
        loop = task
        return await task.value
    }

    private func drain() async -> SyncReport {
        accumulated = SyncReport()
        while !pending.isEmpty {
            let next = pending.removeFirst()
            if Task.isCancelled { break }
            await syncOne(next.id, full: next.full)
        }
        let report = accumulated
        // No suspension point between the empty check above and this line, so no work can be stranded.
        loop = nil
        eventHandler?(.idle)
        return report
    }

    private func syncOne(_ id: String, full: Bool) async {
        guard var subreddit = try? db.subreddit(id: id) else { return }
        eventHandler?(.started(subredditID: id))
        do {
            let newIDs = try await syncSubreddit(subreddit, full: full)
            subreddit = (try? db.subreddit(id: id)) ?? subreddit
            subreddit.lastSynced = Date()
            subreddit.lastError = nil
            try? db.save(subreddit)
            accumulated.syncedSubreddits.append(id)
            accumulated.newThreadIDs += newIDs
            eventHandler?(.finished(subredditID: id, newThreads: newIDs.count))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            subreddit.lastError = message
            try? db.save(subreddit)
            accumulated.failures[id] = message
            eventHandler?(.failed(subredditID: id, message: message))
        }
    }

    // MARK: One subreddit

    func syncSubreddit(_ subreddit: Subreddit, full: Bool) async throws -> [String] {
        let settings = await settings()
        let keep = max(settings.threadsPerSubreddit, 1)

        // 1. Listings. Positions in the top listing become ranks, which stand in for scores feeds don't carry.
        var posts: [PostDTO] = []
        var seen = Set<String>()
        var ranks: [String: Int] = [:]
        var after: String?
        repeat {
            let page = try await api.top(subreddit: subreddit.name, window: subreddit.window, limit: min(100, keep - posts.count), after: after)
            for post in page.children.compactMap(\.data) where seen.insert(post.id).inserted {
                posts.append(post)
                ranks[post.id] = posts.count
            }
            after = page.after
        } while after != nil && posts.count < keep
        let hot = try await api.hot(subreddit: subreddit.name, limit: 50)
        for post in hot.children.compactMap(\.data) where !post.stickied && seen.insert(post.id).inserted {
            posts.append(post)
        }

        // Adopt Reddit's spelling of the name.
        if let canonical = posts.first?.subreddit, canonical != subreddit.name, canonical.lowercased() == subreddit.id {
            var renamed = subreddit
            renamed.name = canonical
            try db.save(renamed)
        }

        // 2. Upsert, fetching comments where needed (best first).
        let existing = Dictionary(uniqueKeysWithValues: try db.threads(ids: posts.map(\.id)).map { ($0.id, $0) })
        posts.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return (ranks[a.id] ?? .max) < (ranks[b.id] ?? .max)
        }
        var newIDs: [String] = []
        var needsComments = posts.filter { post in
            let lowScore = post.score >= 0 && post.score < settings.minimumUpvotes
            let skip = lowScore || (settings.hideImageAndMemePosts && post.isImageOrMeme)
            if skip && !(existing[post.id]?.isSaved ?? false) { return false }
            guard let old = existing[post.id], let fetched = old.commentsFetchedAt else { return true }
            // A full pass also refreshes comments that are more than a day old.
            if full && Date().timeIntervalSince(fetched) > 24 * 3600 { return true }
            // Feeds don't say how many comments a thread has, so only age triggers a refresh there.
            return post.numComments >= 0 && old.numComments != post.numComments
        }
        // Threads never fetched go first, so a capped pass fills gaps before refreshing.
        if let cap = api.commentFetchesPerPass {
            needsComments = Array((needsComments.filter { existing[$0.id]?.commentsFetchedAt == nil }
                + needsComments.filter { existing[$0.id]?.commentsFetchedAt != nil }).prefix(cap))
        }

        // Store every post first so the library fills in before the (slower) comment requests.
        try db.clearTopRanks(subredditID: subreddit.id)
        for post in posts {
            let old = existing[post.id]
            if old == nil { newIDs.append(post.id) }
            var thread = Self.build(post: post, subredditID: subreddit.id, comments: [], limit: 0, existing: old, topRank: ranks[post.id]).thread
            if let old {
                thread.linkCount = max(thread.linkCount, old.linkCount)
                thread.maxDepth = old.maxDepth
                thread.commentsFetchedAt = old.commentsFetchedAt
                if old.kind == .resource { thread.kind = .resource }
            }
            try db.upsert(thread: thread, comments: nil, resources: nil)
        }
        try rescore(subredditID: subreddit.id, settings: settings)

        var completed = 0
        eventHandler?(.progress(subredditID: subreddit.id, completed: 0, total: needsComments.count))
        for post in needsComments {
            try Task.checkCancellation()
            let old = try db.thread(id: post.id)
            let response = try await api.comments(threadID: post.id, limit: settings.commentsPerThread.requestLimit)
            let built = Self.build(post: response.post ?? post, subredditID: subreddit.id, comments: response.comments,
                                   limit: settings.commentsPerThread.storedLimit, existing: old, topRank: ranks[post.id])
            try db.upsert(thread: built.thread, comments: built.comments, resources: built.resources)
            completed += 1
            eventHandler?(.progress(subredditID: subreddit.id, completed: completed, total: needsComments.count))
        }
        // 3–4. Score and prune.
        try rescore(subredditID: subreddit.id, settings: settings)
        let removed = Set(try db.prune(subredditID: subreddit.id, keep: keep))
        let surviving = newIDs.filter { !removed.contains($0) }

        if !settings.boostKeywords.isEmpty {
            let fresh = try db.threads(ids: surviving)
            let globalKeys = Set(settings.boostKeywords.map { $0.lowercased() })
            accumulated.keywordMatches += fresh.filter { t in
                t.matchedKeywords.contains { globalKeys.contains($0.lowercased()) }
                    && (!t.hasScore || t.score >= settings.minimumUpvotes)
            }
        }
        return surviving
    }

    /// Recomputes relevance, why-strings and keyword matches for every thread in a subreddit.
    public func rescore(subredditID: String, settings: AppSettings) throws {
        let subreddit = try db.subreddit(id: subredditID)
        let rows = try db.scoringRows(subredditID: subredditID)
        guard !rows.isEmpty else { return }
        let stats = try db.subredditStats(subredditID: subredditID)
        let keywords = settings.boostKeywords + (subreddit?.keywords ?? [])
        let updates = rows.map { thread, bodies in
            let result = RelevanceScorer.score(
                ScoringInput(subName: subreddit?.name ?? thread.subName, window: subreddit?.window ?? .month,
                             score: thread.score, topRank: thread.topRank, numComments: thread.numComments, maxReplyDepth: thread.maxDepth,
                             uniqueLinkCount: thread.linkCount, title: thread.title, body: thread.body, commentBodies: bodies),
                stats: stats, weights: settings.weights, keywords: keywords
            )
            return (id: thread.id, relevance: result.relevance, why: result.why, matched: result.matchedKeywords)
        }
        try db.updateScores(updates)
    }

    /// Re-scores every subreddit that has threads (after weights or keywords change).
    public func rescoreAll() async throws {
        let settings = await settings()
        let subs = Set(try db.allThreads().map(\.sub))
        for sub in subs { try rescore(subredditID: sub, settings: settings) }
    }

    // MARK: Saved import

    /// Imports the signed-in user's saved posts (needs the `history` scope).
    @discardableResult
    public func importSaved(username: String, maxItems: Int = 1000) async throws -> Int {
        let settings = await settings()
        var after: String?
        var imported = 0
        var touchedSubs = Set<String>()
        repeat {
            let page = try await api.saved(username: username, after: after)
            for post in page.children.compactMap(\.data) {
                let old = try db.thread(id: post.id)
                let subID = post.subreddit.lowercased()
                if old?.commentsFetchedAt == nil || old?.numComments != post.numComments {
                    let response = try await api.comments(threadID: post.id, limit: settings.commentsPerThread.requestLimit)
                    var built = Self.build(post: response.post ?? post, subredditID: subID, comments: response.comments,
                                           limit: settings.commentsPerThread.storedLimit, existing: old, topRank: old?.topRank)
                    built.thread.isSaved = true
                    built.thread.savedOnReddit = true
                    try db.upsert(thread: built.thread, comments: built.comments, resources: built.resources)
                } else if var thread = old {
                    thread.isSaved = true
                    thread.savedOnReddit = true
                    try db.upsert(thread: thread, comments: nil, resources: nil)
                }
                touchedSubs.insert(subID)
                imported += 1
            }
            after = page.after
        } while after != nil && imported < maxItems
        for sub in touchedSubs { try rescore(subredditID: sub, settings: settings) }
        return imported
    }

    // MARK: Building records

    struct Built {
        var thread: RedditThread
        var comments: [Comment]
        var resources: [Resource]
    }

    static func build(post: PostDTO, subredditID: String, comments tree: [CommentDTO], limit: Int?, existing: RedditThread?,
                      topRank: Int? = nil) -> Built {
        var flat = tree.flatMap { $0.flattened() }.filter { $0.body != "[deleted]" && $0.body != "[removed]" }
        if let limit { flat = Array(flat.prefix(limit)) }

        let comments = flat.enumerated().map { i, c in
            Comment(id: c.id, threadId: post.id, author: c.author, body: c.body, score: c.score, depth: c.depth, position: i)
        }

        // Links from the post (outbound URL first, then selftext), then from comments.
        var postLinks: [ExtractedLink] = []
        if let external = post.externalURL, !LinkExtractor.isImageHost(external) {
            postLinks += LinkExtractor.extract(from: external)
        }
        postLinks += LinkExtractor.extract(from: post.selftext)
        var seen = Set<String>()
        var resources: [Resource] = []
        for link in postLinks where seen.insert(link.url).inserted {
            resources.append(Resource(url: link.url, domain: link.domain, title: link.title, threadId: post.id, sourceCommentId: nil))
        }
        for comment in flat {
            for link in LinkExtractor.extract(from: comment.body) where seen.insert(link.url).inserted {
                resources.append(Resource(url: link.url, domain: link.domain, title: link.title, threadId: post.id, sourceCommentId: comment.id))
            }
        }

        let now = Date()
        let fetchedComments = !(tree.isEmpty && limit == 0)
        // Feeds carry no counts: keep what's known, and count the comments a feed returned.
        let score = post.score >= 0 ? post.score : (existing?.score ?? -1)
        let numComments = post.numComments >= 0 ? post.numComments
            : fetchedComments ? comments.count : (existing?.numComments ?? 0)
        let thread = RedditThread(
            id: post.id,
            sub: subredditID,
            subName: post.subreddit,
            title: post.title,
            body: post.selftext,
            author: post.author,
            score: score,
            numComments: numComments,
            createdUTC: Date(timeIntervalSince1970: post.createdUTC),
            permalink: post.permalink,
            postURL: post.externalURL ?? post.url,
            topRank: topRank,
            kind: ThreadClassifier.classify(title: post.title, body: post.selftext, postLinks: postLinks),
            relevance: existing?.relevance ?? 0,
            why: existing?.why ?? "",
            matchedKeywords: existing?.matchedKeywords ?? [],
            isSaved: existing?.isSaved ?? false,
            savedOnReddit: existing?.savedOnReddit ?? false,
            linkCount: resources.count,
            maxDepth: comments.map(\.depth).max() ?? 0,
            isImageOnly: post.isImageOrMeme,
            commentsFetchedAt: fetchedComments ? now : existing?.commentsFetchedAt,
            firstSeenAt: existing?.firstSeenAt ?? now,
            updatedAt: now
        )
        return Built(thread: thread, comments: comments, resources: resources)
    }
}
