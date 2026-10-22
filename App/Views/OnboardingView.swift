import RoundsCore
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    enum Step: Int, CaseIterable {
        case createApp, clientID, subreddits, firstSync

        var title: String {
            switch self {
            case .createApp: "Create a Reddit app"
            case .clientID: "Paste your client ID"
            case .subreddits: "Choose subreddits"
            case .firstSync: "Run the first sync"
            }
        }
    }

    @State private var step: Step = .createApp
    @State private var clientID = ""
    @State private var username = ""
    @State private var verifyMessage: String?
    @State private var verified = false
    @State private var verifying = false
    @State private var syncStarted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color.roundsTeal)
                VStack(alignment: .leading) {
                    Text("Welcome to Rounds").font(.title.weight(.semibold))
                    Text("The best threads and shared resources from your subreddits, searchable offline.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Color.roundsTeal : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)")
                .font(.headline)

            Group {
                switch step {
                case .createApp: createApp
                case .clientID: clientIDStep
                case .subreddits: subredditsStep
                case .firstSync: firstSyncStep
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)

            HStack {
                if step != .createApp {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .createApp }
                }
                Spacer()
                if step == .firstSync {
                    Button(model.isSyncing ? "Continue in Background" : "Done") { model.completeOnboarding() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { advance() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == .clientID && !verified)
                }
            }
        }
        .padding(26)
        .frame(width: 600)
        .onAppear {
            clientID = model.clientID
            username = model.settings.redditUsername
            verified = model.hasClientID
        }
    }

    private func advance() {
        if step == .clientID {
            model.settings.redditUsername = username.trimmingCharacters(in: .whitespaces)
        }
        step = Step(rawValue: step.rawValue + 1) ?? .firstSync
    }

    private var createApp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rounds reads Reddit through the official API, which needs a free app registration in your account. It never posts, votes or comments.")
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open [reddit.com/prefs/apps](https://www.reddit.com/prefs/apps) and sign in.")
                Text("2. Click **create another app…** at the bottom.")
                Text("3. Name it **Rounds** and choose **installed app**.")
                Text("4. Set the redirect URI to **\(RedditOAuthConfig.redirectURI)**.")
                Text("5. Click **create app**. The client ID is the short string under the app name.")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.roundsTeal.opacity(0.08)))
            Link(destination: URL(string: "https://www.reddit.com/prefs/apps")!) {
                Label("Open reddit.com/prefs/apps", systemImage: "arrow.up.right.square")
            }
        }
    }

    private var clientIDStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste the client ID. It's saved in your Keychain, never in the app's files.")
            HStack {
                TextField("Client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onChange(of: clientID) { verified = false; verifyMessage = nil }
                Button("Verify") { verify() }
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || verifying)
            }
            if verifying {
                ProgressView().controlSize(.small)
            } else if let verifyMessage {
                Label(verifyMessage, systemImage: verified ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(verified ? Color.roundsTeal : Color.red)
            }
            Divider().padding(.vertical, 4)
            Text("Your Reddit username (optional). Reddit asks API clients to identify themselves in the User-Agent.")
                .foregroundStyle(.secondary)
            TextField("username", text: $username)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
        }
    }

    private var subredditsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rounds starts with these subreddits. You can add or remove subreddits at any time.")
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.subreddits) { sub in
                        Toggle(isOn: Binding(
                            get: { sub.isEnabled },
                            set: { on in
                                var updated = sub
                                updated.isEnabled = on
                                model.update(updated)
                            }
                        )) {
                            HStack(spacing: 6) {
                                ColorDot(hex: sub.colorHex)
                                Text("r/\(sub.name)")
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }

    private var firstSyncStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rounds pulls the top and hot threads from each subreddit, saves their top comments and every shared link, and scores them for relevance. The first sync takes a few minutes because Reddit limits how fast apps can read.")
            if model.isSyncing || syncStarted {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: model.syncProgress ?? 0)
                    Text(model.syncStatus ?? (model.isSyncing ? "Starting…" : "Finished. \(model.counts.all) threads ready."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let error = model.lastSyncError {
                        Text(error).font(.callout).foregroundStyle(.orange)
                    }
                }
            } else {
                Button {
                    syncStarted = true
                    model.syncNow()
                } label: {
                    Label("Start First Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func verify() {
        verifying = true
        Task {
            await model.setClientID(clientID)
            let error = await model.verifyClientID()
            verified = error == nil
            verifyMessage = error ?? "Connected to Reddit."
            verifying = false
        }
    }
}
