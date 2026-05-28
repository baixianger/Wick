import Foundation

/// Per-host minimum-spacing rate limiter. EastMoney's open endpoints don't
/// document a rate ceiling but quietly start dropping or returning empty bodies
/// when hammered in tight loops (akshare ships ad-hoc sleeps for the same
/// reason). One actor instance per provider is fine — providers share the
/// limiter across all internal sub-fetches so a single snapshot doesn't burst.
public actor HTTPRateLimiter {
    private let minInterval: TimeInterval
    private var lastFire: [String: Date] = [:]

    public init(minInterval: TimeInterval = 0.2) {
        self.minInterval = minInterval
    }

    /// Block until the next call to `host` is allowed, then record it.
    public func acquire(host: String) async {
        let now = Date()
        if let last = lastFire[host] {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < minInterval {
                let wait = minInterval - elapsed
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastFire[host] = Date()
    }
}
