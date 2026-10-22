import AppKit
import AuthenticationServices
import CoreSpotlight
import RoundsCore
import UniformTypeIdentifiers
import UserNotifications

/// Local notifications for new threads that match a boost keyword.
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in }
    }

    static func notify(_ thread: RedditThread) {
        let content = UNMutableNotificationContent()
        content.title = "New in r/\(thread.subName)"
        content.subtitle = thread.matchedKeywords.isEmpty ? "" : "Matches: " + thread.matchedKeywords.joined(separator: ", ")
        content.body = thread.title
        content.threadIdentifier = thread.sub
        let request = UNNotificationRequest(identifier: "thread-\(thread.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { @Sendable _ in }
    }
}

/// Optional CoreSpotlight indexing so threads show up in system search.
enum SpotlightIndexer {
    static let domain = "com.naren.rounds.thread"

    static func index(_ threads: [RedditThread]) {
        guard !threads.isEmpty else { return }
        let items = threads.map { thread -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: UTType.text)
            attributes.title = thread.title
            attributes.contentDescription = "r/\(thread.subName) · \(thread.why)\n" + String(thread.body.prefix(400))
            attributes.keywords = [thread.subName, thread.kind.label] + thread.matchedKeywords
            attributes.contentURL = thread.redditURL
            return CSSearchableItem(uniqueIdentifier: thread.id, domainIdentifier: domain, attributeSet: attributes)
        }
        CSSearchableIndex.default().indexSearchableItems(items) { @Sendable _ in }
    }

    static func removeAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { @Sendable _ in }
    }
}

/// Runs Reddit's OAuth authorization page in a web authentication session and returns the redirect URL.
@MainActor
final class RedditAccountConnector {
    private var session: ASWebAuthenticationSession?
    private let anchor = AuthPresentationAnchor()

    func authorize(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let once = ResumeOnce(continuation)
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: RedditOAuthConfig.callbackScheme
            ) { @Sendable callbackURL, error in
                if let callbackURL {
                    once.resume(.success(callbackURL))
                } else {
                    once.resume(.failure(error ?? RedditError.oauthDenied("cancelled")))
                }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                once.resume(.failure(RedditError.oauthDenied("couldn't open the sign-in window")))
            }
        }
    }
}

/// AuthenticationServices asks for the anchor on the main thread.
@MainActor
final class AuthPresentationAnchor: NSObject, @preconcurrency ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
    }
}

/// Guards a continuation against being resumed twice.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        let pending: CheckedContinuation<T, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}
