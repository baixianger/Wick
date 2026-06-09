import Testing
import Foundation
@testable import TradingFloor

// MARK: - URLProtocol mock for the fflow endpoint

final class FundFlowMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var klines: [String]?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.contains("fflow") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let payload: [String: Any] = Self.klines.map {
            ["data": ["code": "600519", "klines": $0]]
        } ?? ["data": NSNull()]
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
    cfg.protocolClasses = [FundFlowMockURLProtocol.self]
    return URLSession(configuration: cfg)
}

private struct StubBase: MarketDataProvider {
    var technicals: String = ""
    var capitalFlow: String = ""
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        MarketSnapshot(symbol: symbol, asOf: asOf,
                       priceSummary: "", technicals: technicals,
                       fundamentals: [:], news: [], macro: "",
                       capitalFlow: capitalFlow)
    }
}

/// Real row shape from the endpoint: 日期, 主力, 小单, 中单, 大单, 超大单
/// (CNY), then the five as % of turnover, then close/chg legs.
private func seedRows() {
    FundFlowMockURLProtocol.klines = [
        "2026-06-05,-113929472.0,-379347.0,114308816.0,-331703296.0,217773824.0,-2.86,-0.01,2.87,-8.33,5.47,1272.86,0.38,0.00,0.00",
        "2026-06-08,-271861392.0,-236358.0,272097760.0,-50018944.0,-221842448.0,-6.97,-0.01,6.98,-1.28,-5.69,1262.98,-0.78,0.00,0.00",
        "2026-06-09,-200521888.0,-170771.0,200692624.0,-73597520.0,-126924368.0,-5.73,-0.00,5.73,-2.10,-3.63,1256.00,-0.55,0.00,0.00",
    ]
}

// MARK: - Tests

@Suite(.serialized)
struct EastMoneyFundFlowDecoratorTests {

    @Test func renders_today_and_cumulative_flow() async throws {
        seedRows()
        defer { FundFlowMockURLProtocol.klines = nil }

        let dec = EastMoneyFundFlowDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.capitalFlow.contains("资金流向"))
        // Flow lands in its own field, not the technician's indicator block.
        #expect(s.technicals.isEmpty)
        // Today = last row: 主力 -2.01亿 at -5.73% of turnover, 超大单 -1.27亿.
        #expect(s.capitalFlow.contains("今日主力净流入 -2.01亿"))
        #expect(s.capitalFlow.contains("占成交额 -5.73%"))
        #expect(s.capitalFlow.contains("超大单 -1.27亿"))
        // Cumulative over the 3 seeded rows: -5.86亿.
        #expect(s.capitalFlow.contains("近3日主力累计 -5.86亿"))
    }

    @Test func appends_after_existing_capital_flow() async throws {
        seedRows()
        defer { FundFlowMockURLProtocol.klines = nil }

        let dec = EastMoneyFundFlowDecorator(base: StubBase(capitalFlow: "北向净买入 +1.2亿"),
                                             session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.capitalFlow.hasPrefix("北向净买入 +1.2亿\n"))
        #expect(s.capitalFlow.contains("资金流向"))
    }

    @Test func leaves_technicals_untouched() async throws {
        seedRows()
        defer { FundFlowMockURLProtocol.klines = nil }

        // Whatever the technician already wrote must survive — flow no longer
        // routes there.
        let dec = EastMoneyFundFlowDecorator(base: StubBase(technicals: "RSI(14) 64"),
                                             session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.technicals == "RSI(14) 64")
        #expect(!s.technicals.contains("资金流向"))
        #expect(s.capitalFlow.contains("资金流向"))
    }

    @Test func skips_hk_and_non_cn_tickers() async throws {
        seedRows()
        defer { FundFlowMockURLProtocol.klines = nil }

        let dec = EastMoneyFundFlowDecorator(base: StubBase(), session: mockSession())
        for symbol in ["0700.HK", "NVDA"] {
            let s = try await dec.snapshot(symbol: symbol, asOf: Date())
            #expect(!s.capitalFlow.contains("资金流向"), "should skip \(symbol)")
        }
    }

    @Test func endpoint_failure_leaves_capital_flow_untouched() async throws {
        FundFlowMockURLProtocol.klines = nil
        let dec = EastMoneyFundFlowDecorator(base: StubBase(capitalFlow: "北向净买入 +1.2亿"),
                                             session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.capitalFlow == "北向净买入 +1.2亿")
    }

    @Test func cache_serves_same_symbol_same_day() async throws {
        seedRows()
        let dec = EastMoneyFundFlowDecorator(base: StubBase(), session: mockSession())
        let day = Date()
        let first = try await dec.snapshot(symbol: "600519.SS", asOf: day)
        #expect(first.capitalFlow.contains("资金流向"))

        FundFlowMockURLProtocol.klines = nil   // endpoint "down" — cache serves
        let second = try await dec.snapshot(symbol: "600519.SS", asOf: day)
        #expect(second.capitalFlow.contains("资金流向"))
    }
}

// MARK: - Live smoke

@Test(.disabled(if: ProcessInfo.processInfo.environment["EASTMONEY_LIVE"] == nil))
func fund_flow_live_smoke() async throws {
    struct EmptyBase: MarketDataProvider {
        func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
            MarketSnapshot(symbol: symbol, asOf: asOf)
        }
    }
    let dec = EastMoneyFundFlowDecorator(base: EmptyBase())
    let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
    print("[LIVE-FFLOW] \(s.capitalFlow)")
    #expect(s.capitalFlow.contains("今日主力净流入"))
}
