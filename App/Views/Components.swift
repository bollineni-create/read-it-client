import RoundsCore
import SwiftUI

extension Color {
    /// The Rounds accent, #0B6E69.
    static let roundsTeal = Color(red: 11 / 255, green: 110 / 255, blue: 105 / 255)

    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension Date {
    /// Compact age such as "5m", "3h", "2d", "4mo", "1y".
    var shortAge: String {
        let seconds = max(Date().timeIntervalSince(self), 0)
        switch seconds {
        case ..<3600: return "\(max(Int(seconds / 60), 1))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 30): return "\(Int(seconds / 86_400))d"
        case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 30)))mo"
        default: return "\(Int(seconds / (86_400 * 365)))y"
        }
    }
}

extension Int {
    var compact: String {
        if self >= 10_000 { return String(format: "%.0fk", Double(self) / 1000) }
        if self >= 1_000 { return String(format: "%.1fk", Double(self) / 1000) }
        return "\(self)"
    }
}

extension ThreadKind {
    var symbol: String {
        switch self {
        case .discussion: "bubble.left.and.bubble.right"
        case .question: "questionmark.bubble"
        case .resource: "link"
        }
    }
}

struct ColorDot: View {
    let hex: String
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(Color(hex: hex)).frame(width: size, height: size)
    }
}

/// Small rounded label, used for keyword chips and the "Saved" badge.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .roundsTeal
    var prominent = false

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(prominent ? Color.white : tint)
        .background(Capsule().fill(prominent ? tint : tint.opacity(0.14)))
    }
}

/// Lays out children left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                let nextY = current.y + current.height + spacing
                rows.append(current)
                current = Row(y: nextY)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Editable list of keyword chips. Type a keyword and press Return (commas add several at once).
struct KeywordChipEditor: View {
    @Binding var keywords: [String]
    var placeholder = "Add keyword"
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !keywords.isEmpty {
                FlowLayout {
                    ForEach(keywords, id: \.self) { keyword in
                        HStack(spacing: 4) {
                            Text(keyword)
                            Button {
                                keywords.removeAll { $0 == keyword }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(keyword)")
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(Color.roundsTeal)
                        .background(Capsule().fill(Color.roundsTeal.opacity(0.14)))
                    }
                }
            }
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
        }
    }

    private func commit() {
        let new = draft.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for keyword in new where !keywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) {
            keywords.append(keyword)
        }
        draft = ""
    }
}

/// Renders Reddit Markdown paragraph by paragraph with inline styling and working links.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                Text(block)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
    }

    static func blocks(_ markdown: String) -> [AttributedString] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: "\n\n").compactMap { raw in
            let paragraph = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty, paragraph != "&#x200B;" else { return nil }
            let lines = paragraph.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                var l = String(line)
                if let hashes = l.firstIndex(where: { $0 != "#" }), hashes != l.startIndex, l[hashes] == " " {
                    l = "**" + l[l.index(after: hashes)...].trimmingCharacters(in: .whitespaces) + "**"
                } else if l.hasPrefix("* ") || l.hasPrefix("- ") || l.hasPrefix("+ ") {
                    l = "•  " + l.dropFirst(2)
                } else if l.hasPrefix("&gt;") || l.hasPrefix(">") {
                    l = "▎ " + l.drop(while: { $0 == ">" || $0 == " " })
                }
                return l
            }
            let text = lines.joined(separator: "\n")
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        }
    }
}

/// Site icon for a resource, falling back to a link glyph.
struct Favicon: View {
    let domain: String

    var body: some View {
        AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64")) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high)
            } else {
                Image(systemName: "link").foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }
}
