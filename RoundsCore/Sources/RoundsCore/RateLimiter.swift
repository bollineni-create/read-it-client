import Foundation

/// Queues requests so Rounds stays inside Reddit's budget.
///
/// Reddit reports `X-Ratelimit-Remaining`, `X-Ratelimit-Used` and `X-Ratelimit-Reset` (seconds until the window
/// resets). Requests are spaced evenly across what is left of the window, and when the budget is spent the queue
/// waits for the reset.
public actor RateLimiter {
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let minimumInterval: TimeInterval
    private let sleeper: Sleeper
    private let now: @Sendable () -> Date

    private var remaining: Double?
    private var resetAt: Date?
    private var nextSlot: Date = .distantPast
    private var pausedUntil: Date = .distantPast

    public init(
        minimumInterval: TimeInterval = 0.25,
        now: @escaping @Sendable () -> Date = { Date() },
        sleeper: @escaping Sleeper = { seconds in
            if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        }
    ) {
        self.minimumInterval = minimumInterval
        self.now = now
        self.sleeper = sleeper
    }

    /// Waits for this caller's turn. Slots are reserved before sleeping, so concurrent callers queue up in order.
    public func acquire() async throws {
        let current = now()
        var slot = max(current, nextSlot, pausedUntil)

        if let remaining, let resetAt, resetAt > current {
            if remaining < 1 {
                slot = max(slot, resetAt)
                self.remaining = nil
            } else {
                // Spread what's left of the budget over the time left in the window.
                let spacing = resetAt.timeIntervalSince(current) / remaining
                slot = max(slot, nextSlot.addingTimeInterval(max(spacing, minimumInterval) - minimumInterval))
                self.remaining = remaining - 1
            }
        }
        nextSlot = slot.addingTimeInterval(minimumInterval)
        let wait = slot.timeIntervalSince(current)
        if wait > 0 { try await sleeper(wait) }
    }

    /// Records the budget Reddit reported on a response.
    public func update(remaining: Double?, resetSeconds: Double?) {
        if let remaining { self.remaining = remaining }
        if let resetSeconds { self.resetAt = now().addingTimeInterval(resetSeconds) }
    }

    public func update(headers: [String: String]) {
        func value(_ name: String) -> Double? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }.flatMap { Double($0.value) }
        }
        update(remaining: value("X-Ratelimit-Remaining"), resetSeconds: value("X-Ratelimit-Reset"))
    }

    /// Pauses the whole queue after a 429.
    public func backOff(seconds: TimeInterval) {
        pausedUntil = max(pausedUntil, now().addingTimeInterval(seconds))
    }

    public var snapshot: (remaining: Double?, resetAt: Date?) { (remaining, resetAt) }
}
