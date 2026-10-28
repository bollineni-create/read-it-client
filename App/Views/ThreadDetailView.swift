import RoundsCore
import SwiftUI

struct ThreadDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let detail = model.detail {
            ThreadDetailContent(detail: detail)
                .id(detail.thread.id)
        } else {
            ContentUnavailableView("Select a thread", systemImage: "text.bubble",
                                   description: Text("Threads, their shared resources and top comments are stored on this Mac."))
        }
    }
}

private struct ThreadDetailContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let detail: ThreadDetail

    private var thread: RedditThread { detail.thread }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                WhyItSurfacedBox(thread: thread)
                if !thread.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MarkdownText(markdown: thread.body)
                        .font(.body)
                } else if let link = thread.postURL, !link.contains("reddit.com"), let url = URL(string: link) {
                    Link(destination: url) {
                        Label(link, systemImage: "arrow.up.right.square")
                            .lineLimit(1)
                    }
                }
                if !detail.resources.isEmpty { resources }
                if !detail.comments.isEmpty { comments }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ColorDot(hex: model.color(forSub: thread.sub))
                Text("r/\(thread.subName)").fontWeight(.semibold)
                Text("·")
                Label(thread.kind.label, systemImage: thread.kind.symbol)
                Text("·")
                Text("u/\(thread.author)")
                Text("·")
                Text(thread.createdUTC, format: .dateTime.month(.abbreviated).day().year())
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Text(thread.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                if thread.hasScore {
                    Label("\(thread.score.compact) upvotes", systemImage: "arrow.up")
                } else if let rank = thread.topRank {
                    Label("#\(rank) in top posts", systemImage: "chart.bar")
                }
                Label("\(thread.numComments.compact) comments", systemImage: "bubble.left")
                Label("\(thread.linkCount) links", systemImage: "link")
                Spacer()
                if let url = thread.redditURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open on Reddit", systemImage: "safari")
                    }
                }
                Button {
                    model.toggleSaved(thread)
                } label: {
                    Label(thread.isSaved ? "Saved" : "Save", systemImage: thread.isSaved ? "bookmark.fill" : "bookmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(thread.isSaved ? .roundsTeal : .secondary)
                .keyboardShortcut("s", modifiers: .command)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if thread.savedOnReddit {
                Chip(text: "Saved on Reddit", systemImage: "checkmark.seal")
            }
        }
    }

    private var resources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resources in this thread")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(detail.resources) { resource in
                    Button {
                        if let url = URL(string: resource.url) { openURL(url) }
                    } label: {
                        HStack(spacing: 10) {
                            Favicon(domain: resource.domain)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(resource.title).lineLimit(1)
                                Text(resource.domain + (resource.sourceCommentId == nil ? " · in post" : " · in comments"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(resource.url)
                    if resource.id != detail.resources.last?.id {
                        Divider().padding(.leading, 38)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
        }
    }

    private var comments: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top comments")
                .font(.headline)
            ForEach(detail.comments) { comment in
                HStack(alignment: .top, spacing: 10) {
                    if comment.depth > 0 {
                        Rectangle()
                            .fill(Color.roundsTeal.opacity(0.35))
                            .frame(width: 2)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("u/\(comment.author)").fontWeight(.medium)
                            if comment.hasScore {
                                Label(comment.score.compact, systemImage: "arrow.up")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        MarkdownText(markdown: comment.body)
                            .font(.callout)
                    }
                }
                .padding(.leading, CGFloat(min(comment.depth, 6)) * 14)
            }
        }
    }
}

struct WhyItSurfacedBox: View {
    let thread: RedditThread

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Why it surfaced", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.roundsTeal)
                Spacer()
                Text("Relevance \(Int(thread.relevance.rounded()))")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.roundsTeal)
            }
            Text(thread.why.isEmpty ? "Not scored yet." : thread.why)
                .font(.callout)
            if !thread.matchedKeywords.isEmpty {
                FlowLayout {
                    ForEach(thread.matchedKeywords, id: \.self) { keyword in
                        Chip(text: keyword, systemImage: "tag")
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.roundsTeal.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.roundsTeal.opacity(0.25)))
    }
}
