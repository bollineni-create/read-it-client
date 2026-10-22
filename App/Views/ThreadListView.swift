import RoundsCore
import SwiftUI

struct ThreadListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Group {
            if model.threads.isEmpty {
                emptyState
            } else {
                List(model.threads, selection: $model.selectedThreadID) { thread in
                    ThreadRow(thread: thread)
                        .contextMenu {
                            Button(thread.isSaved ? "Unsave" : "Save") { model.toggleSaved(thread) }
                            if let url = thread.redditURL {
                                Link("Open on Reddit", destination: url)
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Sort", selection: $model.sort) {
                ForEach(ThreadSort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(model.scopeTitle)
        .navigationSubtitle("\(model.threads.count) thread\(model.threads.count == 1 ? "" : "s")")
    }

    @ViewBuilder
    private var emptyState: some View {
        let scope = model.selection ?? .all
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if case .subreddit(let id) = scope, model.syncingIDs.contains(id) {
            ContentUnavailableView {
                Label("Syncing r/\(model.subreddit(id: id)?.name ?? id)", systemImage: "arrow.triangle.2.circlepath")
            } description: {
                VStack(spacing: 10) {
                    Text("Pulling top and hot threads, comments and shared links. They'll appear here as soon as the first pass finishes.")
                    ProgressView(value: model.syncProgress ?? 0).frame(width: 180)
                }
            }
        } else if case .subreddit(let id) = scope, let error = model.subreddit(id: id)?.lastError {
            ContentUnavailableView {
                Label("Couldn't sync", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                if let sub = model.subreddit(id: id) {
                    Button("Try Again") { model.syncSubreddit(sub) }
                }
            }
        } else if scope == .saved {
            ContentUnavailableView {
                Label("Nothing saved yet", systemImage: "bookmark")
            } description: {
                Text("Save threads from the detail pane, or connect your Reddit account in Settings to import the threads you've saved there.")
            }
        } else if !model.hasClientID {
            ContentUnavailableView {
                Label("Connect to Reddit", systemImage: "key")
            } description: {
                Text("Add your Reddit client ID to start syncing.")
            } actions: {
                Button("Set Up…") { model.showOnboarding = true }
            }
        } else {
            ContentUnavailableView {
                Label("No threads yet", systemImage: "tray")
            } description: {
                Text(model.isSyncing ? "Sync in progress…" : "Run a sync to pull the most relevant threads.")
            } actions: {
                if !model.isSyncing {
                    Button("Sync Now") { model.syncNow() }
                }
            }
        }
    }
}

struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    let thread: RedditThread

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                ColorDot(hex: model.color(forSub: thread.sub), size: 7)
                Text("r/\(thread.subName) · \(thread.kind.label) · \(thread.createdUTC.shortAge)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if thread.isSaved {
                    Chip(text: "Saved", systemImage: "bookmark.fill", prominent: true)
                }
            }
            Text(thread.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 12) {
                Label(thread.score.compact, systemImage: "arrow.up")
                Label(thread.numComments.compact, systemImage: "bubble.left")
                Label("\(thread.linkCount)", systemImage: "link")
                Spacer()
                Text("\(Int(thread.relevance.rounded()))")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.roundsTeal)
                    .help("Relevance score (0–100)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
    }
}
