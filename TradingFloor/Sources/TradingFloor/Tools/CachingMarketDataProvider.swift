import Foundation

/// Wraps any `MarketDataProvider` with an on-disk, TTL'd cache so repeat
/// lookups don't re-hit the network — conserving the user's own API quota
/// (the whole point in the BYO model). Local only: the cache lives on the
/// user's device, never a server, so there's no data-redistribution concern.
///
/// Decorator pattern: `CachingMarketDataProvider(wrapping: WickYahooProvider())`
/// caches Yahoo today; swap the upstream for Finnhub later, no change here.
public actor CachingMarketDataProvider: MarketDataProvider {
    private let upstream: any MarketDataProvider
    private let ttl: TimeInterval
    private let directory: URL
    private var memory: [String: CacheEntry] = [:]

    private struct CacheEntry: Codable {
        let fetchedAt: Date
        let snapshot: MarketSnapshot
    }

    /// - Parameters:
    ///   - ttl: how long a snapshot stays fresh. Prices go stale fast; pick a
    ///     short TTL for intraday, longer for daily/fundamentals.
    ///   - directory: where to persist. Defaults to the app's caches dir.
    public init(wrapping upstream: any MarketDataProvider,
                ttl: TimeInterval = 900,
                directory: URL? = nil) {
        self.upstream = upstream
        self.ttl = ttl
        self.directory = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TradingFloor/MarketData", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory,
                                                 withIntermediateDirectories: true)
    }

    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        let key = cacheKey(symbol: symbol, asOf: asOf)
        if let entry = entry(for: key), Date().timeIntervalSince(entry.fetchedAt) < ttl {
            return entry.snapshot
        }
        let fresh = try await upstream.snapshot(symbol: symbol, asOf: asOf)
        store(CacheEntry(fetchedAt: .now, snapshot: fresh), for: key)
        return fresh
    }

    // MARK: - Storage (memory + disk)

    private func entry(for key: String) -> CacheEntry? {
        if let hit = memory[key] { return hit }
        let url = directory.appendingPathComponent("\(key).json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let entry = try? decoder.decode(CacheEntry.self, from: data) else { return nil }
        memory[key] = entry
        return entry
    }

    private func store(_ entry: CacheEntry, for key: String) {
        memory[key] = entry
        let url = directory.appendingPathComponent("\(key).json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entry) { try? data.write(to: url) }
    }

    private func cacheKey(symbol: String, asOf: Date) -> String {
        // Day-granular: same ticker on the same day shares a cache slot.
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
        let day = formatter.string(from: asOf)
        let safe = symbol.uppercased().replacingOccurrences(of: "/", with: "_")
        return "\(safe)-\(day)"
    }
}
