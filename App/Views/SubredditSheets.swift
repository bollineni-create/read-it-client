import RoundsCore
import SwiftUI

struct AddSubredditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var window: TimeWindow = .month
    @State private var keywords: [String] = []
    @State private var serverError: String?
    @State private var isChecking = false
    @FocusState private var fieldFocused: Bool

    private var formatError: String? {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if case .failure(let error) = SubredditName.parseNew(text, existing: model.subreddits.map(\.name)) {
            return error.errorDescription
        }
        return nil
    }

    private var suggestions: [String] {
        Subreddit.suggestedNames.filter { !SubredditName.isDuplicate($0, in: model.subreddits.map(\.name)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add subreddit")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 2) {
                    Text("r/")
                        .foregroundStyle(.secondary)
                    TextField("name or reddit.com link", text: $text)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit { add() }
                        .onChange(of: text) { serverError = nil }
                }
                .font(.title3)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder((formatError ?? serverError) == nil ? Color.secondary.opacity(0.3) : Color.red.opacity(0.7)))

                if let message = serverError ?? formatError {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                } else {
                    Text("Accepts r/name, /r/name or a full reddit.com URL.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested").font(.subheadline.weight(.medium))
                    FlowLayout {
                        ForEach(suggestions, id: \.self) { name in
                            Button {
                                text = name
                                add(name)
                            } label: {
                                Label("r/\(name)", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isChecking)
                        }
                    }
                }
            }

            Form {
                Picker("Time window", selection: $window) {
                    ForEach(TimeWindow.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Boost keywords") {
                    KeywordChipEditor(keywords: $keywords, placeholder: "Optional, e.g. MSTP")
                }
            }
            .formStyle(.columns)

            HStack {
                if isChecking {
                    ProgressView().controlSize(.small)
                    Text("Checking Reddit…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || formatError != nil || isChecking)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { fieldFocused = true }
    }

    private func add(_ raw: String? = nil) {
        let input = raw ?? text
        guard !isChecking, !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if case .failure(let error) = SubredditName.parseNew(input, existing: model.subreddits.map(\.name)) {
            serverError = error.errorDescription
            return
        }
        isChecking = true
        serverError = nil
        Task {
            do {
                try await model.addSubreddit(input, window: window, keywords: keywords)
                isChecking = false
                dismiss()
            } catch {
                isChecking = false
                serverError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct EditSubredditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Subreddit

    init(subreddit: Subreddit) {
        _draft = State(initialValue: subreddit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ColorDot(hex: draft.colorHex, size: 12)
                Text("r/\(draft.name)").font(.title2.weight(.semibold))
            }
            Form {
                Picker("Time window", selection: $draft.window) {
                    ForEach(TimeWindow.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Include") {
                    VStack(alignment: .leading) {
                        ForEach(ThreadKind.allCases) { kind in
                            Toggle(kind.label, isOn: Binding(
                                get: { draft.includeKinds.contains(kind) },
                                set: { on in
                                    if on { draft.includeKinds.insert(kind) } else if draft.includeKinds.count > 1 { draft.includeKinds.remove(kind) }
                                }
                            ))
                        }
                    }
                }
                LabeledContent("Boost keywords") {
                    KeywordChipEditor(keywords: $draft.keywords)
                }
                LabeledContent("Color") {
                    HStack(spacing: 6) {
                        ForEach(Subreddit.palette, id: \.self) { hex in
                            Button {
                                draft.colorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 16, height: 16)
                                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: draft.colorHex == hex ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Toggle("Sync this subreddit", isOn: $draft.isEnabled)
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.update(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
