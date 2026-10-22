import AppKit
import RoundsCore
import SwiftUI

@main
struct RoundsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Rounds", id: "main") {
            ContentView()
                .environment(model)
                .tint(.roundsTeal)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Subreddit…") { model.showAddSubreddit = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Library") {
                Button("Sync Now") { model.syncNow() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isSyncing)
                Divider()
                Button("All Threads") { model.selection = .all }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Resources") { model.selection = .resources }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Saved") { model.selection = .saved }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra("Rounds", systemImage: "books.vertical", isInserted: Binding(
            get: { model.settings.syncFromMenuBar },
            set: { model.settings.syncFromMenuBar = $0 }
        )) {
            MenuBarView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Quit with the last window unless menu-bar syncing is on.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !SettingsStore().load().syncFromMenuBar
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isSyncing {
            Text(model.syncStatus ?? "Syncing…")
        } else if let last = model.subreddits.compactMap(\.lastSynced).max() {
            Text("Last synced \(last.formatted(.relative(presentation: .named)))")
        } else {
            Text("Not synced yet")
        }
        Text("\(model.counts.all) threads · \(model.counts.saved) saved")
        Divider()
        Button("Sync Now") { model.syncNow() }
            .disabled(model.isSyncing)
        Button("Open Rounds") {
            openWindow(id: "main")
            NSApplication.shared.activate()
        }
        SettingsLink {
            Text("Settings…")
        }
        Divider()
        Button("Quit Rounds") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
