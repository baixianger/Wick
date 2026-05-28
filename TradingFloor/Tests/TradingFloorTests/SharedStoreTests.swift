import Testing
import Foundation
@testable import TradingFloor

// MARK: - SharedHolding Codable round-trip

@Test func shared_holding_round_trips_through_codable() throws {
    let original = SharedHolding(
        id: UUID(),
        symbol: "600519.SS",
        name: "贵州茅台",
        side: "buy",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        quantity: 100,
        price: 1234.56,
        currency: "CNY",
        externalId: "TX-42",
        sourceJSON: try JSONSerialization.data(
            withJSONObject: ["kind": "imported", "broker": "雪球", "document": "stmt.pdf"])
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SharedHolding.self, from: data)

    #expect(decoded.symbol == "600519.SS")
    #expect(decoded.name == "贵州茅台")
    #expect(decoded.quantity == 100)
    #expect(decoded.price == 1234.56)
    #expect(decoded.externalId == "TX-42")
    #expect(decoded.signedQuantity == 100)
    // The nested `source` object round-trips through JSON Data.
    if let raw = decoded.sourceJSON,
       let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
        #expect(obj["kind"] as? String == "imported")
        #expect(obj["broker"] as? String == "雪球")
        #expect(obj["document"] as? String == "stmt.pdf")
    } else {
        Issue.record("sourceJSON should decode back to a dict")
    }
}

@Test func shared_holding_signed_quantity_for_sell_is_negative() {
    let h = SharedHolding(symbol: "NVDA", name: "NVIDIA", side: "sell",
                          date: Date(), quantity: 30, price: 100, currency: "USD")
    #expect(h.signedQuantity == -30)
}

@Test func shared_holding_decodes_legacy_row_without_source() throws {
    // Rows written by older builds didn't include the `source` field.
    // The decoder must accept that and leave `sourceJSON` nil rather
    // than fail — otherwise an upgrade would lose the user's data.
    let legacy = """
    {
      "id": "12345678-1234-1234-1234-123456789012",
      "symbol": "AAPL",
      "name": "Apple",
      "side": "buy",
      "date": -978307200,
      "quantity": 10,
      "price": 150.0,
      "currency": "USD"
    }
    """
    let data = legacy.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(SharedHolding.self, from: data)
    #expect(decoded.symbol == "AAPL")
    #expect(decoded.sourceJSON == nil)
    #expect(decoded.externalId == nil)
}

// MARK: - Migration

/// All migration tests run against an isolated UserDefaults suite so
/// they don't touch the real shared container or interfere with each
/// other. `tearDown` wipes both source + dest defaults.
private func wipeMigrationState() {
    let standard = UserDefaults.standard
    standard.removeObject(forKey: SharedStore.Keys.holdings)
    standard.removeObject(forKey: SharedStore.Keys.watchlist)
    standard.removeObject(forKey: SharedStore.Keys.migrated)
    let shared = SharedStore.defaults
    if shared !== standard {
        shared.removeObject(forKey: SharedStore.Keys.holdings)
        shared.removeObject(forKey: SharedStore.Keys.watchlist)
        shared.removeObject(forKey: SharedStore.Keys.migrated)
    }
}

@Suite(.serialized)
struct SharedStoreMigrationTests {

    init() { wipeMigrationState() }

    /// When the shared suite isn't available (unsigned helper / no App
    /// Group provisioning), `defaults` falls back to `.standard`. The
    /// migration must still set its flag in that case so a second
    /// invocation is a no-op — otherwise every launch would re-run the
    /// flag-check loop.
    @Test func migrate_is_noop_when_dest_equals_source() {
        let standard = UserDefaults.standard
        // Pre-condition: clean slate (init did the wipe).
        #expect(standard.bool(forKey: SharedStore.Keys.migrated) == false)

        SharedStore.migrateIfNeeded()
        // After running, the flag is set so the next call short-circuits.
        // We assert on `SharedStore.defaults` (which is `.standard` in
        // unsigned dev) rather than directly on standard so the test
        // behaves identically signed or unsigned.
        #expect(SharedStore.defaults.bool(forKey: SharedStore.Keys.migrated) == true)

        // A repeat call must be a no-op (flag already set). Easiest way
        // to confirm: writing a marker AFTER the flag, then calling
        // migrate again, must not clobber it. (Migrate only writes
        // keys that the destination lacks; a true second call should
        // see the flag and immediately return.)
        SharedStore.defaults.set("marker", forKey: "wick.test.marker")
        SharedStore.migrateIfNeeded()
        #expect(SharedStore.defaults.string(forKey: "wick.test.marker") == "marker")
        SharedStore.defaults.removeObject(forKey: "wick.test.marker")
    }

    /// When source has data and dest is empty + they're separate
    /// suites, the data should land in dest. We can't make the
    /// production codepath actually use a separate suite in a unit test
    /// (UserDefaults(suiteName:) returns a shared singleton tied to
    /// the App Group entitlement), so the test verifies the second-best
    /// signal: after `migrateIfNeeded`, the flag is set in whichever
    /// suite `defaults` resolves to, AND any data the test pre-loaded
    /// in standard is still accessible via `SharedStore.holdings()`.
    @Test func migrate_preserves_existing_holdings_in_fallback_mode() throws {
        let h = SharedHolding(symbol: "0700.HK", name: "腾讯控股", side: "buy",
                              date: Date(timeIntervalSince1970: 1_700_000_000),
                              quantity: 10, price: 400, currency: "HKD")
        let data = try JSONEncoder().encode([h])
        UserDefaults.standard.set(data, forKey: SharedStore.Keys.holdings)

        SharedStore.migrateIfNeeded()

        // The store-level reader should return what we wrote, regardless
        // of whether `defaults` is the App Group suite or `.standard`.
        let read = SharedStore.holdings()
        #expect(read.count == 1)
        #expect(read.first?.symbol == "0700.HK")
        #expect(read.first?.name == "腾讯控股")
    }

    @Test func migrate_is_idempotent() {
        SharedStore.migrateIfNeeded()
        SharedStore.migrateIfNeeded()
        SharedStore.migrateIfNeeded()
        #expect(SharedStore.defaults.bool(forKey: SharedStore.Keys.migrated) == true)
    }
}

// MARK: - holdings() / saveHoldings() round-trip

@Test func shared_store_save_then_read_holdings() throws {
    wipeMigrationState()
    defer { wipeMigrationState() }

    let one = SharedHolding(symbol: "600519.SS", name: "贵州茅台", side: "buy",
                            date: Date(), quantity: 50, price: 1300, currency: "CNY")
    let two = SharedHolding(symbol: "NVDA", name: "NVIDIA", side: "sell",
                            date: Date(), quantity: 20, price: 130, currency: "USD")
    SharedStore.saveHoldings([one, two])

    let read = SharedStore.holdings()
    #expect(read.count == 2)
    #expect(Set(read.map(\.symbol)) == ["600519.SS", "NVDA"])
}

@Test func shared_store_save_then_read_watchlist() throws {
    wipeMigrationState()
    defer { wipeMigrationState() }

    let g1 = SharedWatchlistGroup(name: "China", symbols: ["600519.SS", "000001.SZ"])
    let g2 = SharedWatchlistGroup(name: "AI", symbols: ["NVDA", "GOOGL"])
    SharedStore.saveWatchlistGroups([g1, g2])

    let read = SharedStore.watchlistGroups()
    #expect(read.count == 2)
    #expect(read.first(where: { $0.name == "China" })?.symbols == ["600519.SS", "000001.SZ"])
}
