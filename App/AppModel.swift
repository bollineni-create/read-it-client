import AppKit
import Foundation
import Observation
import RoundsCore

/// Settings readable from any isolation domain (the sync engine and the User-Agent closure).
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: AppSettings

    init(_ settings: AppSettings) {
        current = settings
    }

    var value: AppSettings {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: Services

    let db: AppDatabase
    let secrets: SecretStore
    let client: RedditClient
    let engine: SyncEngine
    private let appTokens: AppOnlyTokenProvider
    private let userTokens: UserTokenProvider
    private let settingsStore = SettingsStore()
    private let settingsBox: SettingsBox
    private let connector = RedditAccountConnector()
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var rescoreTask: Task<Void, Never>?
    @ObservationIgnored private var notifiedThreadIDs = Set<String>()

    // MARK: State

    var settings: AppSettings {
        didSet { settingsDidChange(from: oldValue) }
    }

    var subreddits: [Subreddit] = []
    var counts = LibraryCounts()
    var threads: [RedditThread] = []
    var detail: ThreadDetail?

    var selection: LibraryScope? = .all {
        didSet { if oldValue != selection { reloadThreads() } }
    }
    var selectedThreadID: String? {
        didSet { if oldValue != selectedThreadID { loadDetail() } }
    }
    var sort: ThreadSort = .relevance {
        didSet { reloadThreads() }
    }
    var searchText = "" {
        didSet { if oldValue != searchText { reloadThreads() } }
    }

    var isSyncing = false
    var syncingIDs: Set<String> = []
    var syncProgress: Double?
    var syncStatus: String?
    var lastSyncError: String?

    var connectedUsername: String?
    var accountMessage: String?
    var isConnecting = false

    var showAddSubreddit = false
    var editingSubreddit: Subreddit?
    var showOnboarding = false
    /// Mirrors `settings.syncFromMenuBar` so the app's scene body doesn't observe all of `settings`.
    var showsMenuBarExtra = false
    var storageStats: StorageStats?
    var databaseError: String?

    // MARK: Init

    init() {
        let store = SettingsStore()
        let loaded = store.load()
        settings = loaded
        showsMenuBarExtra = loaded.syncFromMenuBar
        let box = SettingsBox(loaded)
        settingsBox = box

        let secrets = KeychainSecretStore()
        self.secrets = secrets

        var dbError: String?
        let database: AppDatabase
        do {
            database = try AppDatabase.open(at: AppDatabase.defaultURL)
        } catch {
            dbError = "Couldn't open the library: \(error.localizedDescription). Using a temporary store."
            database = try! AppDatabase.inMemory()
        }
        db = database
        databaseError = dbError

        let transport = URLSessionTransport()
        let userAgent: @Sendable () -> String = { box.value.userAgent }
        appTokens = AppOnlyTokenProvider(secrets: secrets, transport: transport, userAgent: userAgent)
        userTokens = UserTokenProvider(secrets: secrets, transport: transport, userAgent: userAgent)
        client = RedditClient(transport: transport, appTokens: appTokens, userTokens: userTokens, userAgent: userAgent)
        engine = SyncEngine(db: database, api: client, settings: { box.value })

        connectedUsername = userTokens.isConnected ? secrets.string(for: .username) : nil

        if !loaded.hasCompletedOnboarding {
            try? db.seedDefaultSubredditsIfEmpty()
            showOnboarding = true
        }
        reloadAll()

        let handler: @Sendable (SyncEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let engine = self.engine
        Task { await engine.setEventHandler(handler) }
        startScheduler()
    }

    // MARK: Derived

    var hasClientID: Bool {
        !(secrets.string(for: .clientID) ?? "").isEmpty
    }

    var clientID: String {
        secrets.string(for: .clientID) ?? ""
    }

    var scopeTitle: String {
        switch selection ?? .all {
        case .all: "All threads"
        case .resources: "Resources"
        case .saved: "Saved"
        case .subreddit(let id): "r/" + (subreddits.first { $0.id == id }?.name ?? id)
        }
    }

    func subreddit(id: String) -> Subreddit? {
        subreddits.first { $0.id == id }
    }

    func color(forSub id: String) -> String {
        subreddit(id: id)?.colorHex ?? "#8E8E93"
    }

    // MARK: Loading

    func reloadAll() {
        reloadSubreddits()
        reloadThreads()
        loadDetail()
    }

    func reloadSubreddits() {
        subreddits = (try? db.subreddits()) ?? []
        counts = (try? db.counts(hideImageAndMemePosts: settings.hideImageAndMemePosts,
                                 minimumUpvotes: settings.minimumUpvotes)) ?? LibraryCounts()
    }

    func reloadThreads() {
        let query = ThreadQuery(
            scope: selection ?? .all, sort: sort, search: searchText,
            hideImageAndMemePosts: settings.hideImageAndMemePosts, minimumUpvotes: settings.minimumUpvotes
        )
        threads = (try? db.threads(query)) ?? []
    }

    func loadDetail() {
        guard let id = selectedThreadID else {
            detail = nil
            return
        }
        detail = try? db.detail(threadID: id)
    }

    func refreshStorageStats() {
        storageStats = try? db.storageStats()
    }

    // MARK: Sync

    func syncNow() {
        Task { await sync(ids: nil, full: true) }
    }

    func sync(ids: [String]?, full: Bool) async {
        guard hasClientID else {
            lastSyncError = RedditError.missingClientID.errorDescription
            return
        }
        lastSyncError = nil
        isSyncing = true
        syncingIDs.formUnion(ids ?? subreddits.filter(\.isEnabled).map(\.id))
        let report = await engine.sync(ids, full: full)
        afterSync(report)
    }

    private func afterSync(_ report: SyncReport) {
        reloadAll()
        if !report.failures.isEmpty {
            lastSyncError = report.failures
                .map { "r/\(subreddit(id: $0.key)?.name ?? $0.key): \($0.value)" }
                .sorted().joined(separator: "\n")
        }
        if settings.notifyOnKeywordMatch {
            for thread in report.keywordMatches where notifiedThreadIDs.insert(thread.id).inserted {
                Notifier.notify(thread)
            }
        }
        if settings.indexInSpotlight, !report.newThreadIDs.isEmpty {
            SpotlightIndexer.index((try? db.threads(ids: report.newThreadIDs)) ?? [])
        }
    }

    private func handle(_ event: SyncEvent) {
        switch event {
        case .started(let id):
            isSyncing = true
            syncingIDs.insert(id)
            syncProgress = 0
            syncStatus = "Syncing r/\(subreddit(id: id)?.name ?? id)…"
        case .progress(let id, let done, let total):
            syncProgress = total > 0 ? Double(done) / Double(total) : nil
            let name = subreddit(id: id)?.name ?? id
            syncStatus = total > 0 ? "r/\(name): \(done) of \(total) threads" : "r/\(name): updating"
        case .finished(let id, _), .failed(let id, _):
            syncingIDs.remove(id)
            reloadAll()
        case .idle:
            isSyncing = false
            syncingIDs.removeAll()
            syncProgress = nil
            syncStatus = nil
        }
    }

    private func startScheduler() {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                await self.schedulerTick()
            }
        }
    }

    private func schedulerTick() async {
        guard let interval = settings.syncInterval.seconds, settings.hasCompletedOnboarding,
              hasClientID, !isSyncing else { return }
        let enabled = subreddits.filter(\.isEnabled)
        let due = enabled.filter { Date().timeIntervalSince($0.lastSynced ?? .distantPast) >= interval }.map(\.id)
        guard !due.isEmpty else { return }
        await sync(ids: due, full: false)
    }

    // MARK: Subreddits

    /// Validates the format, checks `/about`, inserts the subreddit and starts its first sync.
    func addSubreddit(_ raw: String, window: TimeWindow, keywords: [String]) async throws {
        let name = try SubredditName.parseNew(raw, existing: subreddits.map(\.name)).get()
        let about = try await client.about(subreddit: name)
        if SubredditName.isDuplicate(about.displayName, in: subreddits.map(\.name)) {
            throw SubredditNameError.duplicate(about.displayName)
        }
        let nextIndex = (subreddits.map(\.sortIndex).max() ?? -1) + 1
        let sub = Subreddit(name: about.displayName, colorHex: Subreddit.color(forIndex: subreddits.count),
                            window: window, keywords: keywords, sortIndex: nextIndex)
        try db.save(sub)
        syncingIDs.insert(sub.id)
        reloadSubreddits()
        selection = .subreddit(sub.id)
        Task { await sync(ids: [sub.id], full: true) }
    }

    func update(_ subreddit: Subreddit) {
        let old = self.subreddit(id: subreddit.id)
        try? db.save(subreddit)
        reloadSubreddits()
        if old?.window != subreddit.window {
            Task { await sync(ids: [subreddit.id], full: false) }
        } else if old?.keywords != subreddit.keywords {
            let settings = self.settings
            Task {
                try? await engine.rescore(subredditID: subreddit.id, settings: settings)
                reloadAll()
            }
        } else {
            reloadThreads()
        }
    }

    func removeSubreddit(_ subreddit: Subreddit) {
        if selection == .subreddit(subreddit.id) { selection = .all }
        try? db.deleteSubreddit(id: subreddit.id)
        if settings.indexInSpotlight { reindexSpotlight() }
        reloadAll()
    }

    func syncSubreddit(_ subreddit: Subreddit) {
        Task { await sync(ids: [subreddit.id], full: true) }
    }

    // MARK: Threads

    func toggleSaved(_ thread: RedditThread) {
        try? db.setSaved(threadID: thread.id, !thread.isSaved)
        reloadAll()
    }

    func reveal(threadID: String) {
        selection = .all
        searchText = ""
        selectedThreadID = threadID
    }

    // MARK: Settings side effects

    private func settingsDidChange(from old: AppSettings) {
        guard settings != old else { return }
        settingsBox.value = settings
        settingsStore.save(settings)

        if old.weights != settings.weights || old.boostKeywords != settings.boostKeywords {
            scheduleRescore()
        }
        if old.hideImageAndMemePosts != settings.hideImageAndMemePosts || old.minimumUpvotes != settings.minimumUpvotes {
            reloadAll()
        }
        if old.syncFromMenuBar != settings.syncFromMenuBar {
            showsMenuBarExtra = settings.syncFromMenuBar
        }
        if old.indexInSpotlight != settings.indexInSpotlight {
            if settings.indexInSpotlight { reindexSpotlight() } else { SpotlightIndexer.removeAll() }
        }
        if settings.notifyOnKeywordMatch && !old.notifyOnKeywordMatch {
            Notifier.requestAuthorization()
        }
    }

    /// Debounced so dragging a weight slider doesn't re-score on every tick.
    private func scheduleRescore() {
        rescoreTask?.cancel()
        rescoreTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            try? await self.engine.rescoreAll()
            self.reloadAll()
        }
    }

    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        showOnboarding = false
    }

    // MARK: Storage

    func rebuildIndex() {
        try? db.rebuildSearchIndex()
        if settings.indexInSpotlight { reindexSpotlight() }
        refreshStorageStats()
        reloadThreads()
    }

    func clearAllData() {
        try? db.clearAllData()
        SpotlightIndexer.removeAll()
        selectedThreadID = nil
        reloadAll()
        refreshStorageStats()
    }

    func reindexSpotlight() {
        SpotlightIndexer.removeAll()
        SpotlightIndexer.index((try? db.allThreads()) ?? [])
    }

    // MARK: Reddit account

    func setClientID(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        secrets.set(trimmed.isEmpty ? nil : trimmed, for: .clientID)
        await appTokens.clearCache()
    }

    /// Fetches an app-only token to prove the client ID works.
    func verifyClientID() async -> String? {
        do {
            _ = try await appTokens.accessToken(forceRefresh: true)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func connectAccount() async {
        guard hasClientID else {
            accountMessage = RedditError.missingClientID.errorDescription
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        let state = UUID().uuidString
        do {
            let url = UserTokenProvider.authorizationURL(clientID: clientID, state: state)
            let callback = try await connector.authorize(url: url)
            try await userTokens.completeAuthorization(callbackURL: callback, expectedState: state)
            let me = try await client.me()
            secrets.set(me.name, for: .username)
            connectedUsername = me.name
            if settings.redditUsername.isEmpty { settings.redditUsername = me.name }
            accountMessage = "Connected as u/\(me.name). Importing saved threads…"
            await importSaved()
        } catch {
            accountMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func importSaved() async {
        guard let username = connectedUsername else { return }
        do {
            let count = try await engine.importSaved(username: username)
            accountMessage = "Imported \(count) saved thread\(count == 1 ? "" : "s") from Reddit."
            reloadAll()
            if settings.indexInSpotlight { reindexSpotlight() }
        } catch {
            accountMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func disconnectAccount() async {
        await userTokens.disconnect()
        connectedUsername = nil
        accountMessage = "Disconnected. Threads you already imported stay in your library."
    }
}
