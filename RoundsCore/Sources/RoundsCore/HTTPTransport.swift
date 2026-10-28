import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The single seam between Rounds and the network. Tests swap in canned JSON.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RedditError.invalidResponse }
        return (data, http)
    }
}

public enum RedditError: Error, Equatable, Sendable, LocalizedError {
    case missingClientID
    case notConnected
    case invalidResponse
    case unauthorized
    case rateLimited
    case http(Int)
    case subredditPrivate(String)
    case subredditBanned(String)
    case subredditQuarantined(String)
    case subredditNotFound(String)
    case oauthDenied(String)
    case decoding(String)
    case needsAPIAccess

    public var errorDescription: String? {
        switch self {
        case .missingClientID: "Add your Reddit client ID in Settings → Reddit Account."
        case .notConnected: "Connect your Reddit account first."
        case .invalidResponse: "Reddit sent an unexpected response."
        case .unauthorized: "Reddit rejected the credentials. Check the client ID."
        case .rateLimited: "Reddit is rate limiting requests. Rounds will retry shortly."
        case .http(let code): "Reddit returned HTTP \(code)."
        case .subredditPrivate(let name): "r/\(name) is private."
        case .subredditBanned(let name): "r/\(name) has been banned."
        case .subredditQuarantined(let name): "r/\(name) is quarantined and can't be read through the API."
        case .subredditNotFound(let name): "r/\(name) doesn't exist."
        case .oauthDenied(let reason): "Reddit sign-in failed: \(reason)."
        case .decoding(let what): "Couldn't read Reddit's response (\(what))."
        case .needsAPIAccess: "This needs a Reddit client ID that Reddit has approved for API access."
        }
    }
}
