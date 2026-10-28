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
            // Our own Quit, so ⌘Q still works while a sheet (like the undismissable onboarding) is up.
            CommandGroup(replacing: .appTermination) {
                Button("Quit Rounds") { AppDelegate.quit() }
                    .keyboardShortcut("q")
            }
            CommandGroup(after: .newItem) {
                Button("Add Subreddit…") { model.showAddSubreddit = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Library") {
                SyncNowCommand(model: model)
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

        // Reads only `showsMenuBarExtra`, and writes back only on a real change: a write during a
        // scene update re-runs this body, which looped until the stack overflowed at launch.
        MenuBarExtra("Rounds", systemImage: "books.vertical", isInserted: Binding(
            get: { model.showsMenuBarExtra },
            set: { if model.settings.syncFromMenuBar != $0 { model.settings.syncFromMenuBar = $0 } }
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

    /// Covers ⌘Q, the Dock menu and the auto-updater's AppleScript `quit`: an open sheet must never hold the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.endSheets()
        return .terminateNow
    }

    @MainActor static func quit() {
        endSheets()
        NSApplication.shared.terminate(nil)
    }

    @MainActor private static func endSheets() {
        for window in NSApplication.shared.windows {
            for sheet in window.sheets { window.endSheet(sheet) }
        }
    }
}

/// A view, not inline in `commands`, so `isSyncing` changes refresh this item instead of the whole app body.
struct SyncNowCommand: View {
    let model: AppModel

    var body: some View {
        Button("Sync Now") { model.syncNow() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isSyncing)
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
        Button("Quit Rounds") { AppDelegate.quit() }
    }
}
