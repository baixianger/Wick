import Testing
import Foundation
@testable import TradingFloor

/// Tags requests with the receiving provider's name so we can verify the
/// router dispatched to the right branch. Mirrors `CountingProvider`'s
/// `@unchecked Sendable` pattern from `TradingFloorTests.swift`.
final class TaggingProvider: MarketDataProvider, @unchecked Sendable {
    let tag: String
    private(set) var hits: [String] = []
    init(_ tag: String) { self.tag = tag }
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        hits.append(symbol)
        return MarketSnapshot(symbol: "\(tag):\(symbol)", asOf: asOf)
    }
}

@Test func router_dispatches_cn_suffixes_to_cn_provider() async throws {
    let cn = TaggingProvider("CN")
    let fallback = TaggingProvider("US")
    let router = MarketRouter(cn: cn, fallback: fallback)

    let day = Date()
    let shanghai = try await router.snapshot(symbol: "600519.SS", asOf: day)
    let shenzhen = try await router.snapshot(symbol: "000001.SZ", asOf: day)
    let hongKong = try await router.snapshot(symbol: "0700.HK", asOf: day)

    #expect(shanghai.symbol == "CN:600519.SS")
    #expect(shenzhen.symbol == "CN:000001.SZ")
    #expect(hongKong.symbol == "CN:0700.HK")
    #expect(cn.hits.count == 3)
    #expect(fallback.hits.isEmpty)
}

@Test func router_sends_us_tickers_to_fallback() async throws {
    let cn = TaggingProvider("CN")
    let fallback = TaggingProvider("US")
    let router = MarketRouter(cn: cn, fallback: fallback)

    let day = Date()
    _ = try await router.snapshot(symbol: "NVDA", asOf: day)
    _ = try await router.snapshot(symbol: "BRK.B", asOf: day)   // class-share, not an exchange suffix

    #expect(cn.hits.isEmpty)
    #expect(fallback.hits == ["NVDA", "BRK.B"])
}

@Test func router_sends_unsupported_intl_to_fallback() async throws {
    // Non-CN international suffixes (`.T`, `.L`) aren't EastMoney's job — the
    // app-side fallback (which wraps a Yahoo provider) deals with those.
    let cn = TaggingProvider("CN")
    let fallback = TaggingProvider("US")
    let router = MarketRouter(cn: cn, fallback: fallback)

    let day = Date()
    _ = try await router.snapshot(symbol: "7203.T", asOf: day)
    _ = try await router.snapshot(symbol: "RIO.L", asOf: day)

    #expect(cn.hits.isEmpty)
    #expect(fallback.hits == ["7203.T", "RIO.L"])
}
