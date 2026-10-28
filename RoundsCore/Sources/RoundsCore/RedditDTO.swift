import Foundation

// Wire formats for the parts of Reddit's API that Rounds reads.

public struct RedditListing<T: Decodable & Sendable>: Decodable, Sendable {
    public var after: String?
    public var children: [T]

    private enum Outer: String, CodingKey { case kind, data }
    private enum Inner: String, CodingKey { case after, children }

    public init(after: String?, children: [T]) {
        self.after = after
        self.children = children
    }

    public init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let inner = try outer.nestedContainer(keyedBy: Inner.self, forKey: .data)
        after = try inner.decodeIfPresent(String.self, forKey: .after)
        children = try inner.decode([T].self, forKey: .children)
    }
}

/// A `t3` child.
public struct PostThing: Decodable, Sendable {
    public var kind: String
    public var data: PostDTO?

    private enum Keys: String, CodingKey { case kind, data }

    public init(_ post: PostDTO) {
        kind = "t3"
        data = post
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = try c.decode(String.self, forKey: .kind)
        data = kind == "t3" ? try c.decode(PostDTO.self, forKey: .data) : nil
    }
}

public struct PostDTO: Decodable, Sendable, Equatable {
    public var id: String
    public var subreddit: String
    public var title: String
    public var selftext: String
    public var author: String
    /// -1 when unknown (posts read from feeds).
    public var score: Int
    /// -1 when unknown (posts read from feeds).
    public var numComments: Int
    public var createdUTC: Double
    public var permalink: String
    public var url: String?
    public var postHint: String?
    public var isSelf: Bool
    public var isGallery: Bool
    public var isVideo: Bool
    public var linkFlairText: String?
    public var stickied: Bool
    public var over18: Bool

    enum CodingKeys: String, CodingKey {
        case id, subreddit, title, selftext, author, score, permalink, url, stickied
        case numComments = "num_comments"
        case createdUTC = "created_utc"
        case postHint = "post_hint"
        case isSelf = "is_self"
        case isGallery = "is_gallery"
        case isVideo = "is_video"
        case linkFlairText = "link_flair_text"
        case over18 = "over_18"
    }

    public init(
        id: String, subreddit: String, title: String, selftext: String = "", author: String, score: Int, numComments: Int,
        createdUTC: Double, permalink: String, url: String? = nil, postHint: String? = nil, isSelf: Bool = true,
        isGallery: Bool = false, isVideo: Bool = false, linkFlairText: String? = nil, stickied: Bool = false, over18: Bool = false
    ) {
        self.id = id
        self.subreddit = subreddit
        self.title = title
        self.selftext = selftext
        self.author = author
        self.score = score
        self.numComments = numComments
        self.createdUTC = createdUTC
        self.permalink = permalink
        self.url = url
        self.postHint = postHint
        self.isSelf = isSelf
        self.isGallery = isGallery
        self.isVideo = isVideo
        self.linkFlairText = linkFlairText
        self.stickied = stickied
        self.over18 = over18
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        subreddit = try c.decode(String.self, forKey: .subreddit)
        title = HTMLEntities.decode(try c.decode(String.self, forKey: .title))
        selftext = HTMLEntities.decode(try c.decodeIfPresent(String.self, forKey: .selftext) ?? "")
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? "[deleted]"
        score = try c.decodeIfPresent(Int.self, forKey: .score) ?? 0
        numComments = try c.decodeIfPresent(Int.self, forKey: .numComments) ?? 0
        createdUTC = try c.decodeIfPresent(Double.self, forKey: .createdUTC) ?? 0
        permalink = try c.decodeIfPresent(String.self, forKey: .permalink) ?? "/comments/\(id)"
        url = try c.decodeIfPresent(String.self, forKey: .url).map(HTMLEntities.decode)
        postHint = try c.decodeIfPresent(String.self, forKey: .postHint)
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        isGallery = try c.decodeIfPresent(Bool.self, forKey: .isGallery) ?? false
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? false
        linkFlairText = try c.decodeIfPresent(String.self, forKey: .linkFlairText)
        stickied = try c.decodeIfPresent(Bool.self, forKey: .stickied) ?? false
        over18 = try c.decodeIfPresent(Bool.self, forKey: .over18) ?? false
    }

    /// Image, gallery or video posts with no text, and posts flaired or titled as memes.
    public var isImageOrMeme: Bool {
        let flair = (linkFlairText ?? "").lowercased()
        let lowerTitle = title.lowercased()
        let memeFlair = ["meme", "humor", "humour", "shitpost", "funny"].contains { flair.contains($0) }
        if memeFlair || ThreadClassifier.containsWord(lowerTitle, "meme") { return true }
        let hasText = !selftext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText { return false }
        if isGallery || isVideo { return true }
        if let hint = postHint, ["image", "hosted:video", "rich:video"].contains(hint) { return true }
        if !isSelf, let url, LinkExtractor.isImageHost(url) { return true }
        return false
    }

    /// The post's outbound URL, when it is a link post to somewhere outside Reddit.
    public var externalURL: String? {
        guard !isSelf, let url, url.hasPrefix("http"), !LinkExtractor.isRedditURL(url) else { return nil }
        return url
    }
}

/// A node of the comment tree (`t1`). `more` stubs are dropped.
public struct CommentDTO: Decodable, Sendable, Equatable {
    public var id: String
    public var author: String
    public var body: String
    public var score: Int
    public var depth: Int
    public var replies: [CommentDTO]

    private enum Keys: String, CodingKey { case id, author, body, score, depth, replies }

    public init(id: String, author: String, body: String, score: Int, depth: Int, replies: [CommentDTO]) {
        self.id = id
        self.author = author
        self.body = body
        self.score = score
        self.depth = depth
        self.replies = replies
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? "[deleted]"
        body = HTMLEntities.decode(try c.decodeIfPresent(String.self, forKey: .body) ?? "")
        score = try c.decodeIfPresent(Int.self, forKey: .score) ?? 0
        depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 0
        // `replies` is "" when empty, otherwise a Listing of things.
        if let listing = try? c.decode(RedditListing<CommentThing>.self, forKey: .replies) {
            replies = listing.children.compactMap(\.comment)
        } else {
            replies = []
        }
    }

    /// Depth-first flattening, which keeps reply chains together.
    public func flattened() -> [CommentDTO] {
        [self] + replies.flatMap { $0.flattened() }
    }
}

public struct CommentThing: Decodable, Sendable {
    public var comment: CommentDTO?

    private enum Keys: String, CodingKey { case kind, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        comment = kind == "t1" ? try c.decode(CommentDTO.self, forKey: .data) : nil
    }
}

/// `/comments/{id}` returns `[postListing, commentListing]`.
public struct CommentsResponse: Decodable, Sendable {
    public var post: PostDTO?
    public var comments: [CommentDTO]

    public init(post: PostDTO?, comments: [CommentDTO]) {
        self.post = post
        self.comments = comments
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let postListing = try c.decode(RedditListing<PostThing>.self)
        let commentListing = try c.decode(RedditListing<CommentThing>.self)
        post = postListing.children.first?.data
        comments = commentListing.children.compactMap(\.comment)
    }
}

/// `/r/{sub}/about`.
public struct SubredditAbout: Decodable, Sendable, Equatable {
    public var displayName: String
    public var subredditType: String
    public var subscribers: Int?
    public var publicDescription: String?
    public var quarantine: Bool

    private enum Outer: String, CodingKey { case kind, data }
    private enum Keys: String, CodingKey {
        case displayName = "display_name"
        case subredditType = "subreddit_type"
        case subscribers
        case publicDescription = "public_description"
        case quarantine
    }

    public init(displayName: String, subredditType: String, subscribers: Int?, publicDescription: String?, quarantine: Bool = false) {
        self.displayName = displayName
        self.subredditType = subredditType
        self.subscribers = subscribers
        self.publicDescription = publicDescription
        self.quarantine = quarantine
    }

    public init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let kind = try outer.decode(String.self, forKey: .kind)
        guard kind == "t5" else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: outer, debugDescription: "Expected t5, got \(kind)")
        }
        let c = try outer.nestedContainer(keyedBy: Keys.self, forKey: .data)
        displayName = try c.decode(String.self, forKey: .displayName)
        subredditType = try c.decodeIfPresent(String.self, forKey: .subredditType) ?? "public"
        subscribers = try c.decodeIfPresent(Int.self, forKey: .subscribers)
        publicDescription = try c.decodeIfPresent(String.self, forKey: .publicDescription)
        quarantine = try c.decodeIfPresent(Bool.self, forKey: .quarantine) ?? false
    }
}

/// `/api/v1/me`.
public struct RedditIdentity: Decodable, Sendable, Equatable {
    public var name: String
}

/// Token endpoint response.
public struct TokenResponse: Decodable, Sendable {
    public var accessToken: String
    public var tokenType: String?
    public var expiresIn: Double
    public var refreshToken: String?
    public var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

/// Body Reddit sends with 403/404 on `/about`.
struct RedditErrorBody: Decodable {
    var reason: String?
    var message: String?
    var error: Int?
}
