import Foundation

/// Decides whether a thread is a Resource, a Question or a Discussion.
public enum ThreadClassifier {
    static let fileExtensions: Set<String> = [
        "pdf", "xlsx", "xls", "csv", "doc", "docx", "ppt", "pptx", "key", "apkg", "zip", "numbers", "pages",
    ]
    static let resourceHosts: [String] = [
        "docs.google.com", "drive.google.com", "sheets.google.com", "dropbox.com", "onedrive.live.com",
        "1drv.ms", "box.com", "notion.so", "notion.site", "ankiweb.net", "github.com", "quizlet.com",
    ]
    static let resourceTerms: [String] = [
        "anki", "deck", "spreadsheet", "google sheet", "template", "pdf", "resource", "resources",
        "cheat sheet", "cheatsheet", "study guide", "flashcards", "notes i made", "free notes",
    ]
    static let questionStarters: Set<String> = [
        "how", "what", "why", "when", "where", "who", "whom", "which", "whose",
        "should", "is", "are", "am", "was", "were", "can", "could", "would", "will", "do", "does", "did",
        "has", "have", "had", "any", "anyone", "anybody", "has anyone", "thoughts", "advice", "help",
    ]

    /// - Parameters:
    ///   - postLinks: external links found in the post itself (URL + selftext), not in comments.
    public static func classify(title: String, body: String, postLinks: [ExtractedLink]) -> ThreadKind {
        if isResource(title: title, body: body, postLinks: postLinks) { return .resource }
        if isQuestion(title) { return .question }
        return .discussion
    }

    public static func isResource(title: String, body: String, postLinks: [ExtractedLink]) -> Bool {
        let shareable = postLinks.filter { !LinkExtractor.isImageHost($0.url) }
        if shareable.contains(where: { link in
            resourceHosts.contains { link.domain == $0 || link.domain.hasSuffix("." + $0) }
                || fileExtensions.contains(((URLComponents(string: link.url)?.path ?? "") as NSString).pathExtension.lowercased())
        }) {
            return true
        }
        let lowerTitle = title.lowercased()
        let mentionsResource = resourceTerms.contains { containsWord(lowerTitle, $0) }
        if mentionsResource && !isQuestion(title) { return true }
        // A post whose body is mostly a list of external links is a resource roundup.
        return shareable.count >= 2
    }

    public static func isQuestion(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") || trimmed.contains("? ") { return true }
        let lower = trimmed.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard let first = words.first else { return false }
        if questionStarters.contains(first) {
            // "Is", "Do" etc. read as questions only when followed by more words.
            return words.count >= 3
        }
        return false
    }

    static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, range: searchRange) {
            let beforeOK = r.lowerBound == haystack.startIndex || !haystack[haystack.index(before: r.lowerBound)].isLetter
            let afterOK = r.upperBound == haystack.endIndex || !haystack[r.upperBound].isLetter
            if beforeOK && afterOK { return true }
            searchRange = r.upperBound..<haystack.endIndex
        }
        return false
    }
}
