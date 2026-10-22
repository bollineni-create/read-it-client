import Foundation

public enum SubredditNameError: Error, Equatable, Sendable, LocalizedError {
    case empty
    case notASubredditURL
    case tooShort
    case tooLong
    case invalidCharacters
    case duplicate(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a subreddit name."
        case .notASubredditURL: "That link doesn't point to a subreddit."
        case .tooShort: "Subreddit names are at least 3 characters."
        case .tooLong: "Subreddit names are at most 21 characters."
        case .invalidCharacters: "Use only letters, numbers and underscores."
        case .duplicate(let name): "r/\(name) is already in your list."
        }
    }
}

/// Parsing and validation of user-entered subreddit names.
public enum SubredditName {
    /// Accepts `name`, `r/name`, `/r/name`, `reddit.com/r/name`, and full `https://…reddit.com/r/name/…` URLs.
    /// Returns the bare name with the user's casing, or a validation error.
    public static func parse(_ raw: String) -> Result<String, SubredditNameError> {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .failure(.empty) }

        let lowered = input.lowercased()
        let looksLikeURL = lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            || lowered.contains("reddit.com/") || lowered.hasPrefix("redd.it/")

        if looksLikeURL {
            let withScheme = lowered.hasPrefix("http") ? input : "https://" + input
            guard let url = URL(string: withScheme), let host = url.host?.lowercased(),
                  host == "reddit.com" || host.hasSuffix(".reddit.com")
            else { return .failure(.notASubredditURL) }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[0].lowercased() == "r" else { return .failure(.notASubredditURL) }
            input = parts[1]
        } else {
            if input.hasPrefix("/") { input.removeFirst() }
            if input.lowercased().hasPrefix("r/") { input.removeFirst(2) }
            if input.hasSuffix("/") { input.removeLast() }
        }

        return validate(input)
    }

    /// Validates a bare name: 3–21 characters of letters, digits or underscores.
    public static func validate(_ name: String) -> Result<String, SubredditNameError> {
        guard !name.isEmpty else { return .failure(.empty) }
        let allowed = name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
        }
        guard allowed else { return .failure(.invalidCharacters) }
        guard name.count >= 3 else { return .failure(.tooShort) }
        guard name.count <= 21 else { return .failure(.tooLong) }
        return .success(name)
    }

    /// Case-insensitive duplicate check.
    public static func isDuplicate(_ name: String, in existing: [String]) -> Bool {
        let key = name.lowercased()
        return existing.contains { $0.lowercased() == key }
    }

    /// Parse, validate and reject duplicates in one step.
    public static func parseNew(_ raw: String, existing: [String]) -> Result<String, SubredditNameError> {
        switch parse(raw) {
        case .failure(let error): return .failure(error)
        case .success(let name):
            if isDuplicate(name, in: existing) { return .failure(.duplicate(name)) }
            return .success(name)
        }
    }
}
