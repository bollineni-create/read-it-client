import RoundsCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            SourcesSettings()
                .tabItem { Label("Sources", systemImage: "list.bullet") }
            RelevanceSettings()
                .tabItem { Label("Relevance", systemImage: "slider.horizontal.3") }
            SyncSettings()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            StorageSettings()
                .tabItem { Label("Search & Storage", systemImage: "internaldrive") }
            AccountSettings()
                .tabItem { Label("Reddit Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 680, height: 500)
        .tint(.roundsTeal)
    }
}

// MARK: - Sources

private struct SourcesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var pendingRemoval: Subreddit?
    @State private var showAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(model.subreddits) {
                TableColumn("Subreddit") { sub in
                    HStack(spacing: 6) {
                        ColorDot(hex: sub.colorHex)
                        Text("r/\(sub.name)")
                            .foregroundStyle(sub.isEnabled ? .primary : .secondary)
                    }
                }
                .width(min: 120, ideal: 150)
                TableColumn("Window") { sub in
                    Picker("Window", selection: Binding(
                        get: { sub.window },
                        set: { newValue in
                            var updated = sub
                            updated.window = newValue
                            model.update(updated)
                        }
                    )) {
                        ForEach(TimeWindow.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                .width(min: 110, ideal: 120)
                TableColumn("Include") { sub in
                    Menu(includeSummary(sub)) {
                        ForEach(ThreadKind.allCases) { kind in
                            Toggle(kind.label, isOn: Binding(
                                get: { sub.includeKinds.contains(kind) },
                                set: { on in
                                    var updated = sub
                                    if on { updated.includeKinds.insert(kind) } else if updated.includeKinds.count > 1 { updated.includeKinds.remove(kind) }
                                    model.update(updated)
                                }
                            ))
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
                .width(min: 100, ideal: 130)
                TableColumn("Last synced") { sub in
                    if let error = sub.lastError {
                        Label("Error", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(error)
                    } else if let date = sub.lastSynced {
                        Text(date, style: .relative) + Text(" ago")
                    } else {
                        Text(model.syncingIDs.contains(sub.id) ? "Syncing…" : "Never")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 90, ideal: 110)
                TableColumn("") { sub in
                    Button(role: .destructive) {
                        pendingRemoval = sub
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Remove r/\(sub.name)")
                }
                .width(28)
            }
            HStack {
                Button {
                    showAdd = true
                } label: {
                    Label("Add subreddit…", systemImage: "plus")
                }
                Spacer()
                Text("Saved threads stay when you remove a subreddit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .confirmationDialog(
            "Remove r/\(pendingRemoval?.name ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { sub in
            Button("Remove", role: .destructive) { model.removeSubreddit(sub) }
        } message: { _ in
            Text("Its threads are deleted from this Mac, except ones you saved.")
        }
        .sheet(isPresented: $showAdd) {
            AddSubredditSheet()
        }
    }

    private func includeSummary(_ sub: Subreddit) -> String {
        if sub.includeKinds.count == ThreadKind.allCases.count { return "All types" }
        return ThreadKind.allCases.filter { sub.includeKinds.contains($0) }.map(\.label).joined(separator: ", ")
    }
}

// MARK: - Relevance

private struct RelevanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                WeightSlider(title: "Upvotes", detail: "Log-scaled, normalized within each subreddit", value: $model.settings.weights.upvotes)
                WeightSlider(title: "Discussion depth", detail: "Comment count plus reply-chain depth", value: $model.settings.weights.discussion)
                WeightSlider(title: "Resources shared", detail: "Unique external links in the post and top comments", value: $model.settings.weights.resources)
                WeightSlider(title: "Keyword match", detail: "Boost keywords in title, body and comments", value: $model.settings.weights.keywords)
                HStack {
                    Spacer()
                    Button("Reset Weights") { model.settings.weights = .default }
                }
            } header: {
                Text("Weights")
            }

            Section {
                KeywordChipEditor(keywords: $model.settings.boostKeywords, placeholder: "Add a keyword and press Return")
            } header: {
                Text("Boost keywords")
            } footer: {
                Text("Applied to every subreddit. Each subreddit can add its own in its settings.")
                    .foregroundStyle(.secondary)
            }

            Section("Filters") {
                Toggle("Hide image-only and meme posts", isOn: $model.settings.hideImageAndMemePosts)
                    .help("Threads from public feeds have no upvote count, so the upvote filter skips them.")
                Stepper(value: $model.settings.minimumUpvotes, in: 0...10_000, step: 5) {
                    LabeledContent("Hide threads with fewer than") {
                        TextField("Upvotes", value: $model.settings.minimumUpvotes, format: .number)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Text("upvotes")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct WeightSlider: View {
    let title: String
    let detail: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...1)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sync

private struct SyncSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Schedule") {
                Picker("Sync", selection: $model.settings.syncInterval) {
                    ForEach(SyncInterval.allCases) { Text($0.label).tag($0) }
                }
                Picker("Threads kept per subreddit", selection: $model.settings.threadsPerSubreddit) {
                    ForEach(AppSettings.threadLimitChoices, id: \.self) { n in
                        Text(n.formatted()).tag(n)
                    }
                }
                Picker("Comments saved per thread", selection: $model.settings.commentsPerThread) {
                    ForEach(CommentLimit.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Background") {
                Toggle("Keep syncing from the menu bar when the window is closed", isOn: $model.settings.syncFromMenuBar)
                Toggle("Notify when a new thread matches a boost keyword", isOn: $model.settings.notifyOnKeywordMatch)
            }
            Section {
                HStack {
                    if model.isSyncing {
                        ProgressView().controlSize(.small)
                        Text(model.syncStatus ?? "Syncing…").foregroundStyle(.secondary)
                    } else if let error = model.lastSyncError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Text("Sync now refreshes every enabled subreddit right away.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sync Now") { model.syncNow() }
                        .disabled(model.isSyncing)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Search & Storage

private struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Library") {
                if let stats = model.storageStats {
                    LabeledContent("Threads", value: stats.threadCount.formatted())
                    LabeledContent("Comments", value: stats.commentCount.formatted())
                    LabeledContent("Resources", value: stats.resourceCount.formatted())
                    LabeledContent("Database size", value: ByteCountFormatter.string(fromByteCount: stats.databaseBytes, countStyle: .file))
                    LabeledContent("Search index size", value: stats.indexBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Included above")
                } else {
                    ProgressView()
                }
            }
            Section("Maintenance") {
                HStack {
                    Button("Rebuild Index") { model.rebuildIndex() }
                    Spacer()
                    Button("Clear All Data…", role: .destructive) { confirmClear = true }
                }
            }
            Section {
                Toggle("Index threads in Spotlight", isOn: $model.settings.indexInSpotlight)
            } footer: {
                Text("Lets you find saved and synced threads from Spotlight. Everything stays on this Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshStorageStats() }
        .confirmationDialog("Delete every stored thread, comment and resource?", isPresented: $confirmClear) {
            Button("Clear All Data", role: .destructive) { model.clearAllData() }
        } message: {
            Text("Your subreddit list and settings are kept. The next sync downloads everything again.")
        }
    }
}

// MARK: - Reddit Account

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var clientID = ""
    @State private var clientIDStatus: String?
    @State private var verifying = false

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                HStack {
                    SecureField("Client ID", text: $clientID)
                        .textFieldStyle(.roundedBorder)
                    Button("Save & Verify") { save() }
                        .disabled(verifying)
                }
                if verifying {
                    ProgressView().controlSize(.small)
                } else if let status = clientIDStatus {
                    Text(status).font(.callout).foregroundStyle(status.hasPrefix("✓") ? Color.roundsTeal : Color.red)
                }
                TextField("Your Reddit username (for the User-Agent)", text: $model.settings.redditUsername)
                    .textFieldStyle(.roundedBorder)
                Text(model.settings.userAgent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } header: {
                Text("API client ID (optional)")
            } footer: {
                Text(model.hasClientID
                     ? "Rounds reads Reddit through the API. Clear the client ID to go back to public feeds."
                     : "Rounds reads Reddit's public feeds. Reddit now approves API access case by case; with an approved “installed app” (redirect URI \(RedditOAuthConfig.redirectURI)), Rounds also gets upvote counts and reply threads. The client ID and tokens are stored in your Keychain.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if let username = model.connectedUsername {
                    LabeledContent("Connected as", value: "u/\(username)")
                    HStack {
                        Button("Import Saved Threads") { Task { await model.importSaved() } }
                        Spacer()
                        Button("Disconnect", role: .destructive) { Task { await model.disconnectAccount() } }
                    }
                } else {
                    HStack {
                        Text(model.hasClientID
                             ? "Connect to import the threads you've saved on Reddit. Rounds asks only for read, history and identity access."
                             : "Importing the threads you've saved on Reddit needs an API client ID.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Connect…") { Task { await model.connectAccount() } }
                            .disabled(!model.hasClientID || model.isConnecting)
                    }
                }
                if model.isConnecting { ProgressView().controlSize(.small) }
                if let message = model.accountMessage {
                    Text(message).font(.callout)
                }
            } header: {
                Text("Reddit account (optional)")
            }
        }
        .formStyle(.grouped)
        .onAppear { clientID = model.clientID }
    }

    private func save() {
        verifying = true
        Task {
            await model.setClientID(clientID)
            if clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clientIDStatus = "✓ Using public feeds."
            } else if let error = await model.verifyClientID() {
                clientIDStatus = error
            } else {
                clientIDStatus = "✓ Client ID works."
            }
            verifying = false
        }
    }
}
