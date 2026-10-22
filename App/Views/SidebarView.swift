import RoundsCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            Section("Library") {
                NavigationLink(value: LibraryScope.all) {
                    Label("All threads", systemImage: "tray.full")
                }
                .badge(model.counts.all)

                NavigationLink(value: LibraryScope.resources) {
                    Label("Resources", systemImage: "link")
                }
                .badge(model.counts.resources)

                NavigationLink(value: LibraryScope.saved) {
                    Label("Saved", systemImage: "bookmark")
                }
                .badge(model.counts.saved)
            }

            Section("Subreddits") {
                ForEach(model.subreddits) { subreddit in
                    NavigationLink(value: LibraryScope.subreddit(subreddit.id)) {
                        SubredditRow(subreddit: subreddit)
                    }
                    .badge(model.counts.bySubreddit[subreddit.id] ?? 0)
                    .contextMenu {
                        Button("Sync r/\(subreddit.name) Now") { model.syncSubreddit(subreddit) }
                        Button("Edit Settings…") { model.editingSubreddit = subreddit }
                        Button(subreddit.isEnabled ? "Pause Syncing" : "Resume Syncing") {
                            var updated = subreddit
                            updated.isEnabled.toggle()
                            model.update(updated)
                        }
                        Divider()
                        Button("Remove r/\(subreddit.name)", role: .destructive) {
                            model.removeSubreddit(subreddit)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    model.showAddSubreddit = true
                } label: {
                    Label("Add subreddit", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

struct SubredditRow: View {
    @Environment(AppModel.self) private var model
    let subreddit: Subreddit

    var body: some View {
        HStack(spacing: 8) {
            ColorDot(hex: subreddit.colorHex)
            Text("r/\(subreddit.name)")
                .foregroundStyle(subreddit.isEnabled ? .primary : .secondary)
            if model.syncingIDs.contains(subreddit.id) {
                ProgressView().controlSize(.mini)
                    .help("Syncing")
            } else if let error = subreddit.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
    }
}
