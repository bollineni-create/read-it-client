import CoreSpotlight
import RoundsCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } content: {
            ThreadListView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 560)
        } detail: {
            ThreadDetailView()
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search threads, comments, links")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SyncToolbarButton()
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $model.showAddSubreddit) {
            AddSubredditSheet()
        }
        .sheet(item: $model.editingSubreddit) { subreddit in
            EditSubredditSheet(subreddit: subreddit)
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                model.reveal(threadID: id)
            }
        }
        .frame(minWidth: 960, minHeight: 600)
    }
}

struct SyncToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.syncNow()
        } label: {
            if model.isSyncing {
                HStack(spacing: 6) {
                    if let progress = model.syncProgress {
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.syncStatus ?? "Syncing…")
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 220)
                }
            } else {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(model.isSyncing)
        .help(model.lastSyncError ?? "Sync every subreddit now")
    }
}
