import Testing
import Foundation
@testable import WickMCP
import TradingFloor

// MARK: - Test fixtures

/// Tagging provider — returns predictable data so we can assert the
/// tool renderer wired the right fields through. No network.
private struct FixtureMarketProvider: MarketDataProvider {
    let lastPrice: Double?
    let fundamentals: [String: String]
    let symbol: String

    init(symbol: String = "TEST",
         lastPrice: Double? = 100,
         fundamentals: [String: String] = [:])
    {
        self.symbol = symbol
        self.lastPrice = lastPrice
        self.fundamentals = fundamentals
    }

    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        MarketSnapshot(symbol: symbol, asOf: asOf,
                       lastPrice: lastPrice,
                       priceSummary: "+1% over 30d",
                       technicals: "RSI 50",
                       fundamentals: fundamentals,
                       news: [])
    }
}

private func makeHost(market: any MarketDataProvider = FixtureMarketProvider())
    -> ToolHost
{
    ToolHost(market: market, eastMoney: EastMoneyMarketDataProvider())
}

private func wipeSharedStore() {
    let suites = [UserDefaults.standard, SharedStore.defaults]
    for s in suites {
        s.removeObject(forKey: SharedStore.Keys.holdings)
        s.removeObject(forKey: SharedStore.Keys.watchlist)
        s.removeObject(forKey: SharedStore.Keys.migrated)
    }
}

// MARK: - Stateless tool dispatch tests (parallel-safe)

@Test func toolhost_lists_all_five_tools() {
    let host = makeHost()
    let names = host.specs.compactMap { $0["name"] as? String }
    #expect(names == [
        "wick.snapshot",
        "wick.candles",
        "wick.holdings",
        "wick.watchlist",
        "wick.portfolio"
    ])
}

@Test func toolhost_every_tool_has_description_and_inputschema() {
    let host = makeHost()
    for spec in host.specs {
        #expect((spec["name"] as? String) != nil)
        #expect((spec["description"] as? String)?.isEmpty == false)
        let schema = spec["inputSchema"] as? [String: Any]
        #expect(schema?["type"] as? String == "object")
    }
}

// MARK: - Dispatch errors

@Test func toolhost_unknown_tool_throws_unknown_error() async {
    let host = makeHost()
    do {
        _ = try await host.call(name: "wick.does_not_exist", arguments: [:])
        Issue.record("Expected MCPToolError.unknown")
    } catch MCPToolError.unknown(let name) {
        #expect(name == "wick.does_not_exist")
    } catch {
        Issue.record("Wrong error type: \(error)")
    }
}

@Test func toolhost_snapshot_missing_ticker_throws_invalid_argument() async {
    let host = makeHost()
    do {
        _ = try await host.call(name: "wick.snapshot", arguments: [:])
        Issue.record("Expected MCPToolError.invalidArgument")
    } catch MCPToolError.invalidArgument {
        // expected
    } catch {
        Issue.record("Wrong error type: \(error)")
    }
}

@Test func toolhost_snapshot_empty_ticker_throws_invalid_argument() async {
    let host = makeHost()
    do {
        _ = try await host.call(name: "wick.snapshot", arguments: ["ticker": ""])
        Issue.record("Expected MCPToolError.invalidArgument")
    } catch MCPToolError.invalidArgument {
        // expected
    } catch {
        Issue.record("Wrong error type: \(error)")
    }
}

// MARK: - wick.snapshot rendering

@Test func toolhost_snapshot_renders_markdown_and_json() async throws {
    let host = makeHost(market: FixtureMarketProvider(
        lastPrice: 250.0,
        fundamentals: ["PE": "30.0", "Market cap": "$3T"]
    ))
    let content = try await host.call(name: "wick.snapshot",
                                       arguments: ["ticker": "TESTING"])
    // Two content blocks: Markdown digest + fenced JSON.
    #expect(content.count == 2)
    let markdown = content[0]["text"] as? String ?? ""
    let json = content[1]["text"] as? String ?? ""
    #expect(markdown.contains("# TESTING"))
    #expect(markdown.contains("**Last price:** 250.00"))
    #expect(markdown.contains("PE: 30.0"))
    #expect(json.contains("```json"))
    #expect(json.contains("TESTING"))
}

@Test func toolhost_snapshot_flags_stub_data() async throws {
    // StubMarketDataProvider tags its output; the renderer should
    // surface that with a "⚠️ Sample data" banner so the calling LLM
    // doesn't treat fake numbers as real.
    let host = makeHost(market: StubMarketDataProvider())
    let content = try await host.call(name: "wick.snapshot",
                                       arguments: ["ticker": "NVDA"])
    let markdown = content[0]["text"] as? String ?? ""
    #expect(markdown.contains("⚠️"))
    #expect(markdown.lowercased().contains("sample"))
    // The internal marker key must NOT leak into the rendered fundamentals.
    #expect(!markdown.contains("_stub"))
}

@Test func toolhost_snapshot_real_data_has_no_warning_banner() async throws {
    let host = makeHost(market: FixtureMarketProvider(lastPrice: 100, fundamentals: ["P/E": "20"]))
    let content = try await host.call(name: "wick.snapshot",
                                       arguments: ["ticker": "REAL"])
    let markdown = content[0]["text"] as? String ?? ""
    #expect(!markdown.contains("⚠️"))
    #expect(!markdown.lowercased().contains("sample data"))
}

// MARK: - State-dependent tests (touch SharedStore; serialized)
//
// SharedStore writes to UserDefaults.standard in unsigned dev builds,
// which is process-global. Running these in parallel lets one test's
// `wipeSharedStore()` clobber another's seed data. The serialized
// suite tag makes Swift Testing run them one at a time.

@Suite(.serialized)
struct ToolHostStatefulTests {

@Test func toolhost_holdings_returns_empty_state_when_no_data() async throws {
    wipeSharedStore()
    defer { wipeSharedStore() }

    let host = makeHost()
    let content = try await host.call(name: "wick.holdings", arguments: [:])
    let text = content[0]["text"] as? String ?? ""
    #expect(text.contains("No holdings"))
}

@Test func toolhost_holdings_renders_seeded_data() async throws {
    wipeSharedStore()
    defer { wipeSharedStore() }

    let row = SharedHolding(
        symbol: "600519.SS", name: "贵州茅台", side: "buy",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        quantity: 100, price: 1300, currency: "CNY")
    SharedStore.saveHoldings([row])

    let host = makeHost()
    let content = try await host.call(name: "wick.holdings", arguments: [:])
    let text = content[0]["text"] as? String ?? ""
    #expect(text.contains("600519.SS"))
    #expect(text.contains("贵州茅台"))
    #expect(text.contains("100"))   // quantity
    // Net-position summary appears when no filter is applied.
    #expect(text.contains("Net positions"))
}

@Test func toolhost_holdings_filters_by_symbol() async throws {
    wipeSharedStore()
    defer { wipeSharedStore() }

    let now = Date()
    SharedStore.saveHoldings([
        SharedHolding(symbol: "AAPL", name: "Apple", side: "buy", date: now,
                      quantity: 10, price: 200, currency: "USD"),
        SharedHolding(symbol: "NVDA", name: "NVIDIA", side: "buy", date: now,
                      quantity: 5, price: 1000, currency: "USD")
    ])

    let host = makeHost()
    let content = try await host.call(name: "wick.holdings",
                                       arguments: ["symbol": "aapl"])
    let text = content[0]["text"] as? String ?? ""
    #expect(text.contains("AAPL"))
    #expect(!text.contains("NVDA"))
}

// MARK: - wick.watchlist

@Test func toolhost_watchlist_empty_state() async throws {
    wipeSharedStore()
    defer { wipeSharedStore() }

    let host = makeHost()
    let content = try await host.call(name: "wick.watchlist", arguments: [:])
    let text = content[0]["text"] as? String ?? ""
    #expect(text.contains("No watchlist"))
}

@Test func toolhost_watchlist_renders_groups() async throws {
    wipeSharedStore()
    defer { wipeSharedStore() }

    SharedStore.saveWatchlistGroups([
        SharedWatchlistGroup(name: "China", symbols: ["600519.SS", "000001.SZ"]),
        SharedWatchlistGroup(name: "AI", symbols: ["NVDA", "GOOGL"])
    ])

    let host = makeHost()
    let content = try await host.call(name: "wick.watchlist", arguments: [:])
    let text = content[0]["text"] as? String ?? ""
    #expect(text.contains("**China**"))
    #expect(text.contains("**AI**"))
    #expect(text.contains("600519.SS"))
    #expect(text.contains("NVDA"))
    #expect(text.contains("2 symbols"))
}

// MARK: - wick.portfolio

@Test func toolhost_portfolio_no_holdings_returns_message() async throws {
    wipeSharedStore()
    defer { wipeSharedStore() }

    let host = makeHost()
    let content = try await host.call(name: "wick.portfolio", arguments: [:])
    let text = content[0]["text"] as? String ?? ""
    #expect(text.contains("No holdings"))
}

@Test func toolhost_portfolio_rolls_up_positions_with_pnl() async throws {
    wipeSharedStore()
    defer { wipeSharedStore() }

    let now = Date()
    SharedStore.saveHoldings([
        SharedHolding(symbol: "TEST", name: "Test Co", side: "buy",
                      date: now, quantity: 100, price: 50, currency: "USD"),
        SharedHolding(symbol: "TEST", name: "Test Co", side: "sell",
                      date: now, quantity: 30, price: 80, currency: "USD")
    ])

    let host = makeHost(market: FixtureMarketProvider(symbol: "TEST", lastPrice: 75))
    let content = try await host.call(name: "wick.portfolio", arguments: [:])
    let text = content[0]["text"] as? String ?? ""
    #expect(text.contains("# Portfolio"))
    #expect(text.contains("TEST"))
    // Net = 100 - 30 = 70 shares; cost basis at avg buy = 50.
    // Last 75 → unrealized P/L = (75 - 50) * 70 = +1750
    #expect(text.contains("Unrealized P/L"))
}

}   // end ToolHostStatefulTests suite
