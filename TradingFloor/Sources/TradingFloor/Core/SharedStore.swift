import Foundation

/// Shared persistence surface between the main Wick app and any bundled
/// helpers (currently `wick-mcp`, the stdio MCP server).
///
/// Both binaries write to / read from the SAME `UserDefaults` suite when
/// the `com.apple.security.application-groups: [group.me.impai.wick]`
/// entitlement is granted to both at sign-time. macOS materializes the
/// suite at `~/Library/Group Containers/<TEAMID>.group.me.impai.wick/…`
/// and both processes get a real, fast, KVO-friendly KV store.
///
/// When the entitlement isn't present (e.g. running unsigned during a
/// `swift run` smoke test, or before the App Group has been provisioned
/// in App Store Connect), `UserDefaults(suiteName:)` silently degrades to
/// a per-process container — each binary then has its own copy of
/// "holdings" / "watchlist". That's by-design: we never want to crash a
/// run because provisioning is incomplete; the data just stops syncing
/// until the entitlement lands.
///
/// **Migration**: the original `HoldingsStore` / `WatchlistStore` used
/// `UserDefaults.standard`. On first launch after this refactor, we copy
/// any data that lives in standard but not in the shared suite — one
/// shot, idempotent, marked via a flag in the destination suite.
public enum SharedStore {

    /// App Group identifier. Must be registered in App Store Connect AND
    /// declared in BOTH the main app's and the helper's entitlements file
    /// for the shared container to materialize. Without that, every call
    /// here silently falls back to the per-process default suite.
    public static let appGroupID = "group.me.impai.wick"

    /// Key namespace stays compatible with the historic `candlekit.*`
    /// keys so an existing install retains its data after migration.
    public enum Keys {
        public static let holdings    = "candlekit.holdings.v1"
        public static let watchlist   = "candlekit.watchlist.groups.v1"
        public static let migrated    = "wick.sharedstore.migrated.v1"
        public static let reportsDir  = "Reports"          // sub-dir inside the App Group container
        public static let reportsMigrated = "wick.sharedstore.reports.migrated.v1"
    }

    /// The shared suite if the App Group is reachable, otherwise the
    /// process's standard defaults. Resolved once per call — UserDefaults
    /// objects are lightweight and ARC-managed, so caching is unnecessary.
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    /// True only when the platform actually handed us the shared
    /// container. Tells the UI whether it can promise cross-process
    /// sync; the MCP setup card surfaces this as a "Sharing with helper:
    /// ✓ / ⚠" line so the user sees if their build isn't entitled.
    public static var isAppGroupAvailable: Bool {
        // `UserDefaults(suiteName:)` returns nil only for invalid names;
        // it does NOT return nil for an unentitled group. We probe by
        // writing + reading a marker into the suite and checking that
        // the same marker appears in the on-disk Group Container path.
        guard let suite = UserDefaults(suiteName: appGroupID) else { return false }
        let probeKey = "wick.sharedstore.probe"
        suite.set(true, forKey: probeKey)
        suite.synchronize()
        // The shared container is `~/Library/Group Containers/<id>/…`
        // for unsandboxed processes, or appears at
        // `~/Library/Group Containers/<TEAMID>.<id>/…` once entitled.
        // We don't need to know the exact path — if the entitlement is
        // missing, the suite ends up writing to the per-process container
        // and the path below won't exist.
        let fm = FileManager.default
        guard let url = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return false
        }
        return fm.fileExists(atPath: url.path)
    }

    // MARK: - Holdings

    public static func holdings() -> [SharedHolding] {
        guard let data = defaults.data(forKey: Keys.holdings) else { return [] }
        return (try? JSONDecoder().decode([SharedHolding].self, from: data)) ?? []
    }

    public static func saveHoldings(_ rows: [SharedHolding]) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        defaults.set(data, forKey: Keys.holdings)
    }

    // MARK: - Watchlist

    public static func watchlistGroups() -> [SharedWatchlistGroup] {
        guard let data = defaults.data(forKey: Keys.watchlist) else { return [] }
        return (try? JSONDecoder().decode([SharedWatchlistGroup].self, from: data)) ?? []
    }

    public static func saveWatchlistGroups(_ groups: [SharedWatchlistGroup]) {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        defaults.set(data, forKey: Keys.watchlist)
    }

    // MARK: - Reports
    //
    // Reports are heavier than holdings (transcripts can be a few KB each)
    // and we want plain-text access for debug grep — so they live as one
    // JSON file per report inside the App-Group container directory,
    // rather than encoded into the UserDefaults plist.

    /// On-disk directory the GUI + helper both read/write reports into.
    /// Returns nil when the App Group container isn't reachable (unsigned
    /// dev build, missing entitlement). Callers should fall back to a
    /// per-process Application Support path in that case so report
    /// history at least survives within one binary.
    public static var reportsDirectoryURL: URL? {
        let fm = FileManager.default
        guard let container = fm.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        let dir = container.appendingPathComponent(Keys.reportsDir, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolves the right reports directory: App Group when entitled,
    /// otherwise `~/Library/Application Support/Wick/Reports/` so the GUI
    /// still works in unsigned dev builds.
    public static var reportsDirectory: URL {
        if let url = reportsDirectoryURL {
            return url
        }
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true))
            ?? fm.temporaryDirectory
        let dir = base
            .appendingPathComponent("Wick", isDirectory: true)
            .appendingPathComponent(Keys.reportsDir, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Load every report in the shared directory, newest first. Bad /
    /// unreadable files are skipped silently — the user can delete them
    /// manually if they ever notice; we never want one corrupt report to
    /// hide the rest.
    public static func reports() -> [Report] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: reportsDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reports = entries.compactMap { url -> Report? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let r = try? decoder.decode(Report.self, from: data)
            else { return nil }
            return r
        }
        return reports.sorted { $0.generatedAt > $1.generatedAt }
    }

    /// Append one report to the shared store. Deduplicated by
    /// `(ticker, generatedAt)` — re-saving the same `Report` returned by
    /// the engine is a no-op, but a genuinely new run on the same day
    /// gets its own file (timestamps differ by at least one second).
    public static func appendReport(_ report: Report) {
        let filename = reportFilename(for: report)
        let url = reportsDirectory.appendingPathComponent(filename)
        // De-dup: if a file with this exact name exists already, skip.
        if FileManager.default.fileExists(atPath: url.path) { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Delete one specific report from the shared store. Used by the GUI
    /// "delete from history" affordance.
    public static func deleteReport(_ report: Report) {
        let url = reportsDirectory.appendingPathComponent(reportFilename(for: report))
        try? FileManager.default.removeItem(at: url)
    }

    /// `<ticker>-<unix-ms>.json`. The unix-ms suffix guarantees uniqueness
    /// across reports written within the same second, which previously
    /// could collide and lose one of two writes.
    private static func reportFilename(for report: Report) -> String {
        let cleanTicker = report.ticker
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let ms = Int(report.generatedAt.timeIntervalSince1970 * 1000)
        return "\(cleanTicker)-\(ms).json"
    }

    // MARK: - Migration

    /// One-shot copy from `UserDefaults.standard` into the shared suite.
    /// Safe to call repeatedly — guarded by a `wick.sharedstore.migrated`
    /// flag in the destination so a second invocation is a no-op. Runs at
    /// app launch (only in the main app — the helper has nothing to
    /// migrate, it's read-only against the existing data).
    public static func migrateIfNeeded() {
        let target = defaults
        let source = UserDefaults.standard
        guard target.bool(forKey: Keys.migrated) == false else { return }
        // Skip if the App Group simply isn't available — there's nothing
        // to copy to (target == source) and we'd just churn the flag.
        guard target !== source else {
            target.set(true, forKey: Keys.migrated)
            return
        }
        // Data keys (blobs).
        for key in [Keys.holdings, Keys.watchlist] {
            if target.data(forKey: key) == nil,
               let data = source.data(forKey: key)
            {
                target.set(data, forKey: key)
            }
        }
        // Companion keys readers in `WatchlistStore.init` (selection) +
        // `HoldingsStore.migrateClearAutoSeededRowsIfNeeded` (the
        // candlekit.holdings.migrate.v4-empty flag) also now read from
        // the shared suite. Migrate them too so users don't lose their
        // selected group OR get auto-seed-cleanup re-applied to
        // hand-typed holdings whose date happens to match a seed row.
        let companionKeys = [
            "candlekit.watchlist.selection.v1",
            "candlekit.holdings.migrate.v4-empty",
        ]
        for key in companionKeys where target.object(forKey: key) == nil {
            if let blob = source.data(forKey: key) {
                target.set(blob, forKey: key)
            } else if let str = source.string(forKey: key) {
                target.set(str, forKey: key)
            } else if source.object(forKey: key) != nil {
                target.set(source.bool(forKey: key), forKey: key)
            }
        }
        target.set(true, forKey: Keys.migrated)
    }
}

// MARK: - Wire types

/// On-disk shape of a holding row. Matches the Codable layout the app's
/// `Holding` struct emits, field-for-field, so the helper can decode
/// rows the main app wrote without sharing the SwiftUI / Observable
/// wrapper code. Adding a field here means also updating the app's
/// `Holding.CodingKeys` to match.
public struct SharedHolding: Codable, Sendable, Hashable {
    public var id: UUID
    public var symbol: String
    public var name: String
    public var side: String        // "buy" / "sell"
    public var date: Date
    public var quantity: Double
    public var price: Double
    public var currency: String
    public var externalId: String?
    /// `HoldingSource` codable shape: { "kind": "manual" | "imported",
    /// "broker"?: String, "document"?: String }. Stored as `Data` so we
    /// don't recreate the discriminated-union decoder here — the helper
    /// only needs to surface it back, not introspect.
    public var sourceJSON: Data?

    public var signedQuantity: Double {
        (side == "sell" ? -1 : 1) * quantity
    }

    enum CodingKeys: String, CodingKey {
        case id, symbol, name, side, date, quantity, price, currency
        case externalId, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.symbol = try c.decode(String.self, forKey: .symbol)
        self.name = try c.decode(String.self, forKey: .name)
        self.side = try c.decode(String.self, forKey: .side)
        self.date = try c.decode(Date.self, forKey: .date)
        self.quantity = try c.decode(Double.self, forKey: .quantity)
        self.price = try c.decode(Double.self, forKey: .price)
        self.currency = try c.decode(String.self, forKey: .currency)
        self.externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        // The `source` field is a small nested object; capture it as raw
        // JSON Data instead of duplicating its discriminated-union decoder.
        if c.contains(.source) {
            let nested = try c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .source)
            let dict = try Self.decodeAnyDict(from: nested)
            self.sourceJSON = try JSONSerialization.data(withJSONObject: dict)
        } else {
            self.sourceJSON = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,        forKey: .id)
        try c.encode(symbol,    forKey: .symbol)
        try c.encode(name,      forKey: .name)
        try c.encode(side,      forKey: .side)
        try c.encode(date,      forKey: .date)
        try c.encode(quantity,  forKey: .quantity)
        try c.encode(price,     forKey: .price)
        try c.encode(currency,  forKey: .currency)
        try c.encodeIfPresent(externalId, forKey: .externalId)
        // Re-emit captured source as nested JSON if we have it.
        if let data = sourceJSON,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            var nested = c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .source)
            try Self.encodeAnyDict(obj, to: &nested)
        }
    }

    /// Convenience init for testing / programmatic construction. Most
    /// callers don't need this — the helper reads holdings via decode.
    public init(id: UUID = UUID(),
                symbol: String,
                name: String,
                side: String,
                date: Date,
                quantity: Double,
                price: Double,
                currency: String,
                externalId: String? = nil,
                sourceJSON: Data? = nil)
    {
        self.id = id
        self.symbol = symbol
        self.name = name
        self.side = side
        self.date = date
        self.quantity = quantity
        self.price = price
        self.currency = currency
        self.externalId = externalId
        self.sourceJSON = sourceJSON
    }

    // MARK: - Untyped-dict round-tripping (for nested `source`)

    private static func decodeAnyDict(
        from container: KeyedDecodingContainer<AnyCodingKey>
    ) throws -> [String: Any] {
        var out: [String: Any] = [:]
        for key in container.allKeys {
            if let s = try? container.decode(String.self, forKey: key) {
                out[key.stringValue] = s
            } else if let i = try? container.decode(Int.self, forKey: key) {
                out[key.stringValue] = i
            } else if let d = try? container.decode(Double.self, forKey: key) {
                out[key.stringValue] = d
            } else if let b = try? container.decode(Bool.self, forKey: key) {
                out[key.stringValue] = b
            }
        }
        return out
    }

    private static func encodeAnyDict(
        _ dict: [String: Any],
        to container: inout KeyedEncodingContainer<AnyCodingKey>
    ) throws {
        for (k, v) in dict {
            guard let key = AnyCodingKey(stringValue: k) else { continue }
            switch v {
            case let s as String: try container.encode(s, forKey: key)
            case let i as Int:    try container.encode(i, forKey: key)
            case let d as Double: try container.encode(d, forKey: key)
            case let b as Bool:   try container.encode(b, forKey: key)
            default: break
            }
        }
    }
}

public struct SharedWatchlistGroup: Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var symbols: [String]

    public init(id: UUID = UUID(), name: String, symbols: [String]) {
        self.id = id; self.name = name; self.symbols = symbols
    }
}

/// JSON's "any string key" helper for the nested-source decoder.
private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int)       { self.stringValue = String(intValue) }
}
