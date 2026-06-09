import Testing
import Foundation
@testable import TradingFloor

// MARK: - URLProtocol mock for the RZRQ_GGMX endpoint

final class MarginMockURLProtocol: URLProtocol, @unchecked Sendable {
    /// Set to a single JSON row dict to serve `{result:{data:[row]}}`; nil →
    /// `{result:null,success:false}` (endpoint "down").
    nonisolated(unsafe) static var row: [String: Any]?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.absoluteString.contains("RPTA_WEB_RZRQ_GGMX") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let payload: [String: Any] = Self.row.map {
            ["result": ["data": [$0]], "success": true, "code": 0]
        } ?? ["result": NSNull(), "success": false, "code": 9701]
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
    cfg.protocolClasses = [MarginMockURLProtocol.self]
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

/// Captured real row for 600519 (2026-06-08) from RPTA_WEB_RZRQ_GGMX.
private func seedRow() {
    MarginMockURLProtocol.row = [
        "DATE": "2026-06-08 00:00:00",
        "SCODE": "600519",
        "RZYE": 19498594489,
        "FIN_BALANCE_GR": -1.214708302796,
        "RZYEZB": 1.2350043,
        "RZJME": -239763472,
        "RQYE": 137841637.2,
    ]
}

// MARK: - Tests

@Suite(.serialized)
struct EastMoneyMarginDecoratorTests {

    @Test func renders_margin_line() async throws {
        seedRow()
        defer { MarginMockURLProtocol.row = nil }

        let dec = EastMoneyMarginDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.capitalFlow.contains("融资融券"))
        // 融资余额 194.99亿 (-1.21%); 融资净买入 -2.40亿; 占流通市值 +1.24%; 融券余额 1.38亿.
        #expect(s.capitalFlow.contains("融资余额 194.99亿"))
        #expect(s.capitalFlow.contains("-1.21%"))
        #expect(s.capitalFlow.contains("融资净买入 -2.40亿"))
        #expect(s.capitalFlow.contains("占流通市值 +1.24%"))
        #expect(s.capitalFlow.contains("融券余额 1.38亿"))
    }

    @Test func appends_after_existing_capital_flow() async throws {
        seedRow()
        defer { MarginMockURLProtocol.row = nil }

        let dec = EastMoneyMarginDecorator(base: StubBase(capitalFlow: "资金流向: …"),
                                           session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.capitalFlow.hasPrefix("资金流向: …\n"))
        #expect(s.capitalFlow.contains("融资融券"))
    }

    @Test func skips_hk_and_non_cn_tickers() async throws {
        seedRow()
        defer { MarginMockURLProtocol.row = nil }

        let dec = EastMoneyMarginDecorator(base: StubBase(), session: mockSession())
        for symbol in ["0700.HK", "NVDA"] {
            let s = try await dec.snapshot(symbol: symbol, asOf: Date())
            #expect(!s.capitalFlow.contains("融资融券"), "should skip \(symbol)")
        }
    }

    @Test func endpoint_failure_leaves_capital_flow_untouched() async throws {
        MarginMockURLProtocol.row = nil
        let dec = EastMoneyMarginDecorator(base: StubBase(capitalFlow: "资金流向: …"),
                                           session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.capitalFlow == "资金流向: …")
    }

    @Test func cache_serves_same_symbol_same_day() async throws {
        seedRow()
        let dec = EastMoneyMarginDecorator(base: StubBase(), session: mockSession())
        let day = Date()
        let first = try await dec.snapshot(symbol: "600519.SS", asOf: day)
        #expect(first.capitalFlow.contains("融资融券"))

        MarginMockURLProtocol.row = nil   // endpoint "down" — cache serves
        let second = try await dec.snapshot(symbol: "600519.SS", asOf: day)
        #expect(second.capitalFlow.contains("融资融券"))
    }
}

// MARK: - Live smoke

@Test(.disabled(if: ProcessInfo.processInfo.environment["EASTMONEY_LIVE"] == nil))
func margin_live_smoke() async throws {
    struct EmptyBase: MarketDataProvider {
        func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
            MarketSnapshot(symbol: symbol, asOf: asOf)
        }
    }
    let dec = EastMoneyMarginDecorator(base: EmptyBase())
    let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
    print("[LIVE-MARGIN] \(s.capitalFlow)")
    #expect(s.capitalFlow.contains("融资融券"))
}
