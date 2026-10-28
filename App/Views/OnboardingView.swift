import RoundsCore
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    enum Step: Int, CaseIterable {
        case source, subreddits, firstSync

        var title: String {
            switch self {
            case .source: "How Rounds reads Reddit"
            case .subreddits: "Choose subreddits"
            case .firstSync: "Run the first sync"
            }
        }
    }

    @State private var step: Step = .source
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
                case .source: sourceStep
                case .subreddits: subredditsStep
                case .firstSync: firstSyncStep
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)

            HStack {
                if step != .source {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .source }
                }
                Spacer()
                if step == .firstSync {
                    Button(model.isSyncing ? "Continue in Background" : "Done") { model.completeOnboarding() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { advance() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(verifying)
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
        if step == .source {
            model.settings.redditUsername = username.trimmingCharacters(in: .whitespaces)
        }
        step = Step(rawValue: step.rawValue + 1) ?? .firstSync
    }

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rounds reads each subreddit's public feed, so there's nothing to set up. It never posts, votes or comments.")
            Text("Feeds list the top 100 posts of the period with their text and top comments, but no upvote counts, so Rounds ranks threads by their place in Reddit's top list.")
                .foregroundStyle(.secondary)
            Text("Your Reddit username (optional). Rounds sends it in the User-Agent so Reddit knows who's asking.")
                .foregroundStyle(.secondary)
            TextField("username", text: $username)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            DisclosureGroup("I have a Reddit API client ID") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reddit now approves API access case by case. With an approved “installed app” client ID, Rounds also gets upvote counts and reply threads, and can import your saved posts. It's stored in your Keychain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                }
                .padding(.top, 6)
            }
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
            Text("Rounds pulls the top and hot threads from each subreddit, saves their top comments and every shared link, and scores them for relevance. Threads show up right away; comments fill in over the next few syncs because Reddit limits how fast apps can read.")
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
            if error != nil { await model.setClientID("") }
            verified = error == nil
            verifyMessage = error ?? "Connected to Reddit."
            verifying = false
        }
    }
}
