import Foundation

/// A link found in a post or comment, already normalized.
public struct ExtractedLink: Hashable, Sendable {
    public var url: String
    public var domain: String
    public var title: String
}

/// Pulls links out of Reddit Markdown, normalizes them and drops duplicates.
public enum LinkExtractor {
    /// Query parameters that only carry tracking information.
    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "igshid", "igsh",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "ref", "ref_src", "ref_url", "referrer",
        "si", "spm", "share_id", "trk", "trkinfo", "oly_anon_id", "oly_enc_id", "vero_id", "rb_clickid",
        "s_cid", "cmpid", "src", "feature", "ved", "ei", "sca_esv", "_ga", "_gl", "context",
    ]

    /// Hosts that belong to Reddit itself; links to them are navigation, not shared resources.
    static let redditHosts: [String] = ["reddit.com", "redd.it", "redditmedia.com", "redditstatic.com", "reddituploads.com"]

    nonisolated(unsafe) private static let markdownLink = try! NSRegularExpression(
        pattern: #"\[([^\]\n]{0,300})\]\(\s*<?(https?://[^\s)>]+(?:\([^\s)]*\)[^\s)>]*)*)>?(?:\s+"[^"]*")?\s*\)"#,
        options: [.caseInsensitive]
    )
    nonisolated(unsafe) private static let bareURL = try! NSRegularExpression(
        pattern: #"https?://[^\s<>\[\]"'`|]+"#,
        options: [.caseInsensitive]
    )

    /// Extracts unique, normalized external links in order of first appearance.
    public static func extract(from markdown: String) -> [ExtractedLink] {
        let text = HTMLEntities.decode(markdown)
        let ns = text as NSString
        var found: [(range: NSRange, url: String, title: String?)] = []

        for match in markdownLink.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let title = ns.substring(with: match.range(at: 1))
            let url = ns.substring(with: match.range(at: 2))
            found.append((match.range, url, title))
        }
        let markdownRanges = found.map(\.range)
        for match in bareURL.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if markdownRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            found.append((match.range, trimTrailing(ns.substring(with: match.range)), nil))
        }
        found.sort { $0.range.location < $1.range.location }

        var seen = Set<String>()
        var result: [ExtractedLink] = []
        for item in found {
            guard let normalized = normalize(item.url) else { continue }
            guard !isRedditURL(normalized.url) else { continue }
            guard seen.insert(normalized.url).inserted else { continue }
            result.append(ExtractedLink(
                url: normalized.url,
                domain: normalized.domain,
                title: displayTitle(markdownTitle: item.title, url: normalized.url, domain: normalized.domain)
            ))
        }
        return result
    }

    /// Normalizes a URL: lower-cases scheme and host, drops `www.`, the fragment, default ports and
    /// tracking parameters, unwraps common redirectors and removes a trailing slash.
    public static func normalize(_ raw: String) -> (url: String, domain: String)? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\(", with: "(")
            .replacingOccurrences(of: "\\)", with: ")")
            .replacingOccurrences(of: "\\~", with: "~")
        guard var components = URLComponents(string: cleaned) ?? URLComponents(string: percentEscape(cleaned)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(), !host.isEmpty, host.contains(".")
        else { return nil }

        // Unwrap redirectors such as google.com/url?q=… and out.reddit.com/…?url=….
        if let target = redirectTarget(host: host, components: components), target != raw {
            return normalize(target)
        }

        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasPrefix("m.") && host != "m.me" { host.removeFirst(2) }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }

        if let items = components.queryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
            }
            components.queryItems = kept.isEmpty ? nil : kept
        }

        if components.path == "/" { components.path = "" }
        if components.path.count > 1 && components.path.hasSuffix("/") { components.path.removeLast() }

        guard let string = components.string else { return nil }
        return (string, host)
    }

    public static func isRedditURL(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return redditHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Links that point at media hosted by Reddit or image hosts, used to detect image-only posts.
    public static func isImageHost(_ url: String) -> Bool {
        guard let comps = URLComponents(string: url), let host = comps.host?.lowercased() else { return false }
        let imageHosts = ["i.redd.it", "v.redd.it", "preview.redd.it", "i.imgur.com", "imgur.com", "gfycat.com", "giphy.com", "media.giphy.com"]
        if imageHosts.contains(host) { return true }
        let ext = (comps.path as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "gifv", "webp", "mp4", "heic"].contains(ext)
    }

    // MARK: Helpers

    private static func redirectTarget(host: String, components: URLComponents) -> String? {
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch host {
        case "google.com", "www.google.com":
            return components.path == "/url" ? (value("q") ?? value("url")) : nil
        case "out.reddit.com":
            return value("url")
        case "l.facebook.com", "lm.facebook.com":
            return value("u")
        case "youtube.com", "www.youtube.com":
            return components.path == "/redirect" ? value("q") : nil
        default:
            return nil
        }
    }

    /// Drops punctuation that commonly trails a URL in prose, keeping balanced parentheses.
    static func trimTrailing(_ url: String) -> String {
        var s = url
        while let last = s.last {
            if ".,;:!?*'\"".contains(last) {
                s.removeLast()
            } else if last == ")" {
                let opens = s.filter { $0 == "(" }.count
                let closes = s.filter { $0 == ")" }.count
                if closes > opens { s.removeLast() } else { break }
            } else if last == "\\" {
                s.removeLast()
            } else {
                break
            }
        }
        return s
    }

    private static func percentEscape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(.urlPathAllowed)) ?? s
    }

    static func displayTitle(markdownTitle: String?, url: String, domain: String) -> String {
        if let t = markdownTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
           normalize(t)?.url != url, !t.lowercased().hasPrefix("http") {
            return t
        }
        if let comps = URLComponents(string: url) {
            let last = comps.path.split(separator: "/").last.map(String.init) ?? ""
            let decoded = last.removingPercentEncoding ?? last
            let stem = (decoded as NSString).deletingPathExtension
            let pretty = stem.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            let isOpaqueID = pretty.count > 24 && !pretty.contains(" ")
            if !pretty.isEmpty, !isOpaqueID, pretty.rangeOfCharacter(from: .letters) != nil {
                let ext = (decoded as NSString).pathExtension
                return ext.isEmpty ? pretty : "\(pretty).\(ext)"
            }
        }
        return domain
    }
}

/// Reddit returns selftext with HTML entities escaped.
public enum HTMLEntities {
    private static let table: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"),
        ("&nbsp;", " "), ("&#x200B;", ""), ("&#8203;", ""), ("&amp;", "&"),
    ]

    public static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (entity, replacement) in table {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out
    }
}
