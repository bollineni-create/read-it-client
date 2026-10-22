import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RoundsCore

final class RedditClientTests: XCTestCase {
    func testDecodesListingAndSendsHeaders() async throws {
        let transport = MockTransport()
        transport.on("/r/mdphd/top", body: Fixtures.mdphdTop, headers: ["X-Ratelimit-Remaining": "99", "X-Ratelimit-Reset": "60"])
        let listing = try await makeClient(transport).top(subreddit: "mdphd", window: .month, limit: 100, after: nil)

        XCTAssertEqual(listing.children.compactMap(\.data).map(\.id), ["a1", "a2", "a3", "a4", "a5"])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.host, "oauth.reddit.com")
        XCTAssertTrue(request.url?.query?.contains("t=month") ?? false)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "macos:com.naren.rounds:v1.0 (by /u/tester)")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testDecodesCommentTreeAndSkipsMoreStubs() async throws {
        let transport = MockTransport()
        transport.on("/comments/a1", body: Fixtures.a1Comments)
        let response = try await makeClient(transport).comments(threadID: "a1", limit: 20)
        XCTAssertEqual(response.post?.id, "a1")
        XCTAssertEqual(response.comments.map(\.id), ["c1", "c4"])
        XCTAssertEqual(response.comments[0].flattened().map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(response.comments[0].flattened().map(\.depth), [0, 1, 2])
        XCTAssertTrue(transport.requests[0].url!.query!.contains("sort=top"))
    }

    func testDetectsImageAndMemePosts() async throws {
        let transport = MockTransport()
        transport.on("/r/mdphd/top", body: Fixtures.mdphdTop)
        let posts = try await makeClient(transport).top(subreddit: "mdphd", window: .week, limit: 10, after: nil).children.compactMap(\.data)
        XCTAssertEqual(posts.filter(\.isImageOrMeme).map(\.id), ["a3"])
    }

    func testRetriesAfter429() async throws {
        let transport = MockTransport()
        transport.on("/r/mdphd/hot", status: 429, body: "{}", headers: ["Retry-After": "0"])
        transport.on("/r/mdphd/hot", status: 429, body: "{}")
        transport.on("/r/mdphd/hot", body: Fixtures.mdphdHot)
        let listing = try await makeClient(transport).hot(subreddit: "mdphd", limit: 50)
        XCTAssertEqual(listing.children.count, 2)
        XCTAssertEqual(transport.requestedPaths.count, 3)
    }

    func testGivesUpAfterRepeated429() async {
        let transport = MockTransport()
        transport.on("/r/mdphd/hot", status: 429, body: "{}")
        do {
            _ = try await makeClient(transport).hot(subreddit: "mdphd", limit: 50)
            XCTFail("expected rateLimited")
        } catch {
            XCTAssertEqual(error as? RedditError, .rateLimited)
            XCTAssertEqual(transport.requestedPaths.count, 5, "first try plus four retries")
        }
    }

    func testAboutValidation() async throws {
        let transport = MockTransport()
        transport.on("/r/premed/about", body: Fixtures.aboutPublic)
        transport.on("/r/secret/about", status: 403, body: Fixtures.aboutPrivateBody)
        transport.on("/r/gone/about", status: 404, body: Fixtures.aboutBannedBody)
        transport.on("/r/nothing/about", status: 404, body: Fixtures.aboutMissingBody)
        transport.on("/r/redirected/about", body: Fixtures.searchRedirectListing)
        let client = makeClient(transport)

        let about = try await client.about(subreddit: "premed")
        XCTAssertEqual(about.displayName, "premed")

        for (name, expected) in [
            ("secret", RedditError.subredditPrivate("secret")),
            ("gone", .subredditBanned("gone")),
            ("nothing", .subredditNotFound("nothing")),
            ("redirected", .subredditNotFound("redirected")),
        ] {
            do {
                _ = try await client.about(subreddit: name)
                XCTFail("expected error for \(name)")
            } catch {
                XCTAssertEqual(error as? RedditError, expected)
            }
        }
    }

    func testRateLimiterWaitsForResetWhenBudgetIsSpent() async throws {
        let clock = TestClock()
        let limiter = RateLimiter(minimumInterval: 0, now: { clock.now }, sleeper: { clock.advance($0) })
        await limiter.update(remaining: 0, resetSeconds: 30)
        try await limiter.acquire()
        XCTAssertEqual(clock.slept, 30, accuracy: 0.001)
    }

    func testRateLimiterBacksOff() async throws {
        let clock = TestClock()
        let limiter = RateLimiter(minimumInterval: 0, now: { clock.now }, sleeper: { clock.advance($0) })
        await limiter.backOff(seconds: 8)
        try await limiter.acquire()
        XCTAssertEqual(clock.slept, 8, accuracy: 0.001)
    }

    func testAppOnlyTokenUsesInstalledClientGrant() async throws {
        let transport = MockTransport()
        transport.on("/api/v1/access_token", body: Fixtures.token)
        let secrets = InMemorySecretStore([.clientID: "my-client-id"])
        let provider = AppOnlyTokenProvider(secrets: secrets, transport: transport, userAgent: { "ua" })

        let token = try await provider.accessToken(forceRefresh: false)
        XCTAssertEqual(token, "app-token")
        let request = try XCTUnwrap(transport.requests.first)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=https%3A%2F%2Foauth.reddit.com%2Fgrants%2Finstalled_client"), body)
        XCTAssertTrue(body.contains("device_id="))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("my-client-id:".utf8).base64EncodedString())

        // Cached in the secret store: no second request.
        _ = try await provider.accessToken(forceRefresh: false)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertNotNil(secrets.string(for: .appToken))
    }

    func testMissingClientID() async {
        let provider = AppOnlyTokenProvider(secrets: InMemorySecretStore(), transport: MockTransport(), userAgent: { "ua" })
        do {
            _ = try await provider.accessToken(forceRefresh: false)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? RedditError, .missingClientID)
        }
    }

    func testAuthorizationURL() {
        let url = UserTokenProvider.authorizationURL(clientID: "cid", state: "xyz")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "read history identity")
        XCTAssertEqual(items.first { $0.name == "duration" }?.value, "permanent")
        XCTAssertEqual(items.first { $0.name == "redirect_uri" }?.value, "rounds://oauth")
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    private(set) var slept: TimeInterval = 0

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
        slept += seconds
    }
}
