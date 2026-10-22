import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Configuration shared by the OAuth pieces.
public struct RedditOAuthConfig: Sendable {
    public static let tokenURL = URL(string: "https://www.reddit.com/api/v1/access_token")!
    public static let authorizeURL = URL(string: "https://www.reddit.com/api/v1/authorize")!
    public static let installedClientGrant = "https://oauth.reddit.com/grants/installed_client"
    public static let redirectURI = "rounds://oauth"
    public static let callbackScheme = "rounds"
    public static let userScopes = ["read", "history", "identity"]
}

struct StoredToken: Codable {
    var accessToken: String
    var expiresAt: Date
}

/// Issues bearer tokens.
public protocol TokenProvider: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

/// Shared helpers for talking to the token endpoint.
struct TokenEndpoint {
    let transport: HTTPTransport
    let userAgent: @Sendable () -> String

    func request(clientID: String, form: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: RedditOAuthConfig.tokenURL)
        request.httpMethod = "POST"
        // Installed apps have no secret: the Basic credential is "clientID:".
        let credential = Data("\(clientID):".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(formEncode(form).utf8)

        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200: break
        case 401, 403: throw RedditError.unauthorized
        case 429: throw RedditError.rateLimited
        default: throw RedditError.http(response.statusCode)
        }
        if let err = try? JSONDecoder().decode([String: String].self, from: data), let message = err["error"] {
            throw RedditError.oauthDenied(message)
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw RedditError.decoding("token")
        }
    }
}

func formEncode(_ pairs: [(String, String)]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return pairs.map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(k)=\(v)"
    }.joined(separator: "&")
}

/// Application-only OAuth for installed apps (`grants/installed_client`). Tokens are cached in the secret store.
public actor AppOnlyTokenProvider: TokenProvider {
    private let secrets: SecretStore
    private let endpoint: TokenEndpoint
    private var inFlight: Task<String, Error>?

    public init(secrets: SecretStore, transport: HTTPTransport, userAgent: @escaping @Sendable () -> String) {
        self.secrets = secrets
        self.endpoint = TokenEndpoint(transport: transport, userAgent: userAgent)
    }

    /// A stable per-install identifier, 20–30 characters as Reddit requires.
    public nonisolated static func deviceID(in secrets: SecretStore) -> String {
        if let existing = secrets.string(for: .deviceID) { return existing }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(30).lowercased()
        secrets.set(String(id), for: .deviceID)
        return String(id)
    }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached = cachedToken() { return cached }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.fetch() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    public func clearCache() {
        secrets.set(nil, for: .appToken)
    }

    private func cachedToken() -> String? {
        guard let raw = secrets.string(for: .appToken),
              let token = try? JSONDecoder().decode(StoredToken.self, from: Data(raw.utf8)),
              token.expiresAt > Date().addingTimeInterval(60)
        else { return nil }
        return token.accessToken
    }

    private func fetch() async throws -> String {
        guard let clientID = secrets.string(for: .clientID)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientID.isEmpty
        else { throw RedditError.missingClientID }
        let response = try await endpoint.request(clientID: clientID, form: [
            ("grant_type", RedditOAuthConfig.installedClientGrant),
            ("device_id", Self.deviceID(in: secrets)),
        ])
        store(response)
        return response.accessToken
    }

    private func store(_ response: TokenResponse) {
        let token = StoredToken(accessToken: response.accessToken, expiresAt: Date().addingTimeInterval(response.expiresIn))
        if let data = try? JSONEncoder().encode(token) {
            secrets.set(String(decoding: data, as: UTF8.self), for: .appToken)
        }
    }
}

/// The signed-in user's tokens (authorization-code flow, `duration=permanent`).
public actor UserTokenProvider: TokenProvider {
    private let secrets: SecretStore
    private let endpoint: TokenEndpoint

    public init(secrets: SecretStore, transport: HTTPTransport, userAgent: @escaping @Sendable () -> String) {
        self.secrets = secrets
        self.endpoint = TokenEndpoint(transport: transport, userAgent: userAgent)
    }

    public nonisolated var isConnected: Bool {
        secrets.string(for: .userRefreshToken) != nil
    }

    /// URL to open in a web authentication session.
    public nonisolated static func authorizationURL(clientID: String, state: String) -> URL {
        var comps = URLComponents(url: RedditOAuthConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: RedditOAuthConfig.redirectURI),
            URLQueryItem(name: "duration", value: "permanent"),
            URLQueryItem(name: "scope", value: RedditOAuthConfig.userScopes.joined(separator: " ")),
        ]
        return comps.url!
    }

    /// Parses the redirect (`rounds://oauth?state=…&code=…`) and exchanges the code for tokens.
    public func completeAuthorization(callbackURL: URL, expectedState: String) async throws {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw RedditError.oauthDenied(error) }
        guard value("state") == expectedState else { throw RedditError.oauthDenied("state mismatch") }
        guard let code = value("code") else { throw RedditError.oauthDenied("missing code") }
        guard let clientID = secrets.string(for: .clientID), !clientID.isEmpty else { throw RedditError.missingClientID }

        let response = try await endpoint.request(clientID: clientID, form: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", RedditOAuthConfig.redirectURI),
        ])
        store(response)
        if let refresh = response.refreshToken { secrets.set(refresh, for: .userRefreshToken) }
    }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let raw = secrets.string(for: .userAccessToken),
           let token = try? JSONDecoder().decode(StoredToken.self, from: Data(raw.utf8)),
           token.expiresAt > Date().addingTimeInterval(60) {
            return token.accessToken
        }
        guard let refresh = secrets.string(for: .userRefreshToken) else { throw RedditError.notConnected }
        guard let clientID = secrets.string(for: .clientID), !clientID.isEmpty else { throw RedditError.missingClientID }
        let response = try await endpoint.request(clientID: clientID, form: [
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh),
        ])
        store(response)
        return response.accessToken
    }

    public func disconnect() {
        secrets.set(nil, for: .userAccessToken)
        secrets.set(nil, for: .userRefreshToken)
        secrets.set(nil, for: .username)
    }

    private func store(_ response: TokenResponse) {
        let token = StoredToken(accessToken: response.accessToken, expiresAt: Date().addingTimeInterval(response.expiresIn))
        if let data = try? JSONEncoder().encode(token) {
            secrets.set(String(decoding: data, as: UTF8.self), for: .userAccessToken)
        }
    }
}
