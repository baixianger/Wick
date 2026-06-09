import Testing
import Foundation
@testable import TradingFloor

// MARK: - URLProtocol mock for the DAILYBILLBOARD endpoint

final class BillboardMockURLProtocol: URLProtocol, @unchecked Sendable {
    /// Single JSON row dict → `{result:{data:[row]}}`; nil → failure envelope.
    nonisolated(unsafe) static var row: [String: Any]?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.absoluteString.contains("RPT_DAILYBILLBOARD_DETAILSNEW") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let payload: [String: Any] = Self.row.map {
            ["result": ["data": [$0]], "success": true, "code": 0]
        } ?? ["result": NSNull(), "success": false, "code": 0]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let resp = HTTPURLResponse(url: url, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [BillboardMockURLProtocol.self]
    return URLSession(configuration: cfg)
}

private struct StubBase: MarketDataProvider {
    var capitalFlow: String = ""
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        MarketSnapshot(symbol: symbol, asOf: asOf,
                       priceSummary: "", technicals: "",
                       fundamentals: [:], news: [], macro: "",
                       capitalFlow: capitalFlow)
    }
}

/// UTC date string `yyyy-MM-dd HH:mm:ss` `offsetDays` before `from` — used to
/// place the seeded billboard appearance relative to the test's `asOf`.
private func billboardDate(daysAgo: Int, from: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: from.addingTimeInterval(TimeInterval(-daysAgo) * 86_400))
}

/// Captured real-shape row for 000001 (2024-02-21 appearance), re-dated to
/// `daysAgo` so recency gating can be exercised deterministically.
private func seedRow(daysAgo: Int, asOf: Date) {
    BillboardMockURLProtocol.row = [
        "TRADE_DATE": billboardDate(daysAgo: daysAgo, from: asOf),
        "SECURITY_CODE": "000001",
        "NET_BS_AMT": 565226781.19,
        "EXPLANATION": "日涨幅偏离值达到7%的前5只证券",
        "EXPLAIN": "主力做T，成功率45.73%",
    ]
}

// MARK: - Tests

@Suite(.serialized)
struct EastMoneyBillboardDecoratorTests {

    @Test func renders_recent_billboard_line() async throws {
        let asOf = Date()
        seedRow(daysAgo: 1, asOf: asOf)
        defer { BillboardMockURLProtocol.row = nil }

        let dec = EastMoneyBillboardDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "000001.SZ", asOf: asOf)
        #expect(s.capitalFlow.contains("龙虎榜"))
        #expect(s.capitalFlow.contains("上榜"))
        // 净买入 5.65亿; seat read carried through.
        #expect(s.capitalFlow.contains("净买入 5.65亿"))
        #expect(s.capitalFlow.contains("主力做T"))
    }

    @Test func skips_stale_appearance() async throws {
        let asOf = Date()
        // Outside the 5-day window → treated as "not on a recent billboard".
        seedRow(daysAgo: 400, asOf: asOf)
        defer { BillboardMockURLProtocol.row = nil }

        let dec = EastMoneyBillboardDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "000001.SZ", asOf: asOf)
        #expect(!s.capitalFlow.contains("龙虎榜"))
    }

    @Test func appends_after_existing_capital_flow() async throws {
        let asOf = Date()
        seedRow(daysAgo: 0, asOf: asOf)
        defer { BillboardMockURLProtocol.row = nil }

        let dec = EastMoneyBillboardDecorator(base: StubBase(capitalFlow: "融资融券: …"),
                                              session: mockSession())
        let s = try await dec.snapshot(symbol: "000001.SZ", asOf: asOf)
        #expect(s.capitalFlow.hasPrefix("融资融券: …\n"))
        #expect(s.capitalFlow.contains("龙虎榜"))
    }

    @Test func skips_hk_and_non_cn_tickers() async throws {
        let asOf = Date()
        seedRow(daysAgo: 0, asOf: asOf)
        defer { BillboardMockURLProtocol.row = nil }

        let dec = EastMoneyBillboardDecorator(base: StubBase(), session: mockSession())
        for symbol in ["0700.HK", "NVDA"] {
            let s = try await dec.snapshot(symbol: symbol, asOf: asOf)
            #expect(!s.capitalFlow.contains("龙虎榜"), "should skip \(symbol)")
        }
    }

    @Test func endpoint_failure_leaves_capital_flow_untouched() async throws {
        BillboardMockURLProtocol.row = nil
        let dec = EastMoneyBillboardDecorator(base: StubBase(capitalFlow: "融资融券: …"),
                                              session: mockSession())
        let s = try await dec.snapshot(symbol: "000001.SZ", asOf: Date())
        #expect(s.capitalFlow == "融资融券: …")
    }

    @Test func cache_serves_same_symbol_same_day() async throws {
        let asOf = Date()
        seedRow(daysAgo: 1, asOf: asOf)
        let dec = EastMoneyBillboardDecorator(base: StubBase(), session: mockSession())
        let first = try await dec.snapshot(symbol: "000001.SZ", asOf: asOf)
        #expect(first.capitalFlow.contains("龙虎榜"))

        BillboardMockURLProtocol.row = nil   // endpoint "down" — cache serves
        let second = try await dec.snapshot(symbol: "000001.SZ", asOf: asOf)
        #expect(second.capitalFlow.contains("龙虎榜"))
    }
}

// MARK: - Live smoke

@Test(.disabled(if: ProcessInfo.processInfo.environment["EASTMONEY_LIVE"] == nil))
func billboard_live_smoke() async throws {
    struct EmptyBase: MarketDataProvider {
        func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
            MarketSnapshot(symbol: symbol, asOf: asOf)
        }
    }
    // 600519 only has historical appearances, so this asserts the endpoint
    // responds + parses, not that a line is rendered (it won't be, unless the
    // stock is on a recent list).
    let dec = EastMoneyBillboardDecorator(base: EmptyBase())
    let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
    print("[LIVE-BILLBOARD] capitalFlow=\(s.capitalFlow)")
}
