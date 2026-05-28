import Testing
import Foundation
@testable import TradingFloor

// MARK: - URLProtocol mock

/// Routes EastMoney URLs to canned JSON payloads. Set the static `handlers`
/// table before constructing the provider; reset it after each test.
final class EastMoneyMockURLProtocol: URLProtocol, @unchecked Sendable {
    /// (host, path) → canned response body
    nonisolated(unsafe) static var handlers: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host.contains("eastmoney.com")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let key = "\(url.host ?? "")\(url.path)"
        guard let body = Self.handlers[key] else {
            // Default: 404 with empty body so the provider can demonstrate
            // graceful degradation.
            let response = HTTPURLResponse(url: url, statusCode: 404,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [EastMoneyMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func provider() -> EastMoneyMarketDataProvider {
    EastMoneyMarketDataProvider(
        session: mockSession(),
        limiter: HTTPRateLimiter(minInterval: 0)   // no throttling in tests
    )
}

// MARK: - Fixtures

private func kLineFixture(rows: [String]) -> Data {
    // Mirrors the EastMoney `push2his/kline/get` response shape — only the
    // fields the provider reads (data.klines) are populated.
    let payload: [String: Any] = ["data": ["klines": rows]]
    return try! JSONSerialization.data(withJSONObject: payload)
}

private func quoteFixture(_ fields: [String: Any]) -> Data {
    let payload: [String: Any] = ["data": fields]
    return try! JSONSerialization.data(withJSONObject: payload)
}

/// 250 sessions of mildly-uptrending data so the technicals helpers have
/// enough points to compute RSI, MACD, and both SMAs.
private func syntheticKLineRows(count: Int = 250) -> [String] {
    (0..<count).map { i in
        let close = 50.0 + Double(i) * 0.1   // 50.0 → 74.9
        let open = close - 0.05
        let high = close + 0.2
        let low = close - 0.2
        // date,open,close,high,low,volume,amount,amplitude,pct_chg,chg,turnover
        return String(format: "2024-01-%02d,%.2f,%.2f,%.2f,%.2f,100000,5000000,1.0,0.2,0.10,0.5",
                      (i % 28) + 1, open, close, high, low)
    }
}

// MARK: - Tests
//
// Suite is `.serialized` because all the provider tests share one global
// `URLProtocol` handler table. Running them in parallel (Swift Testing's
// default) lets one test's fixtures bleed into another's assertions.

@Suite(.serialized)
struct EastMoneyProviderTests {

@Test func eastmoney_rejects_non_cn_symbol() async {
    let p = provider()
    EastMoneyMockURLProtocol.handlers = [:]
    defer { EastMoneyMockURLProtocol.handlers = [:] }

    do {
        _ = try await p.snapshot(symbol: "NVDA", asOf: Date())
        Issue.record("Expected EastMoneyError.notCNSymbol")
    } catch is EastMoneyError {
        // expected
    } catch {
        Issue.record("Wrong error type: \(error)")
    }
}

@Test func eastmoney_builds_snapshot_from_kline_and_quote() async throws {
    let p = provider()
    EastMoneyMockURLProtocol.handlers = [
        "push2his.eastmoney.com/api/qt/stock/kline/get":
            kLineFixture(rows: syntheticKLineRows()),
        "push2delay.eastmoney.com/api/qt/stock/get":
            quoteFixture([
                "f43": 74.9,                // current price
                "f48": 1_234_567_890.0,     // amount today
                "f57": "600519",
                "f58": "贵州茅台",
                "f116": 1_800_000_000_000.0, // 1.8 万亿 total cap
                "f117": 1_700_000_000_000.0, // free float cap
                "f127": "白酒",
                "f162": 28.4,               // PE
                "f167": 9.1,                // PB
                "f168": 0.42,               // turnover today
                "f173": 32.5                // ROE
            ])
    ]
    defer { EastMoneyMockURLProtocol.handlers = [:] }

    let snap = try await p.snapshot(symbol: "600519.SS", asOf: Date())

    #expect(snap.symbol == "600519.SS")
    #expect(snap.lastPrice == 74.9)
    #expect(snap.fundamentals["名称"] == "贵州茅台")
    #expect(snap.fundamentals["行业"] == "白酒")
    #expect(snap.fundamentals["总市值"] == "1.80万亿")
    #expect(snap.fundamentals["流通市值"] == "1.70万亿")
    #expect(snap.fundamentals["PE(TTM)"] == "28.4")
    #expect(snap.fundamentals["PB"] == "9.10")
    #expect(snap.fundamentals["ROE"] == "32.5%")
    #expect(snap.fundamentals["换手率"] == "0.42%")
    #expect(snap.fundamentals["市场"] == "沪市A股")
    #expect(snap.fundamentals["52周高低"] != nil)

    // Technicals helper ran (250 closes → RSI + MACD + both SMAs populate).
    #expect(snap.technicals.contains("RSI"))
    #expect(snap.technicals.contains("MACD"))
    #expect(snap.technicals.contains("SMA"))
    #expect(snap.priceSummary.contains("over ~30d"))
}

@Test func eastmoney_handles_dash_as_missing_numeric() async throws {
    // EastMoney returns `"-"` for fields it doesn't have (e.g. PE for newly-
    // listed names or 港股 where ROE isn't published). The decoder must treat
    // that as nil instead of throwing.
    let p = provider()
    EastMoneyMockURLProtocol.handlers = [
        "push2his.eastmoney.com/api/qt/stock/kline/get":
            kLineFixture(rows: syntheticKLineRows()),
        "push2delay.eastmoney.com/api/qt/stock/get":
            quoteFixture([
                "f43": 320.5,
                "f57": "0700",
                "f58": "腾讯控股",
                "f127": "互联网",
                "f162": "-",                  // PE missing
                "f167": "-",                  // PB missing
                "f168": "-",
                "f173": "-",
                "f116": 3_000_000_000_000.0
            ])
    ]
    defer { EastMoneyMockURLProtocol.handlers = [:] }

    let snap = try await p.snapshot(symbol: "0700.HK", asOf: Date())
    #expect(snap.lastPrice == 320.5)
    #expect(snap.fundamentals["名称"] == "腾讯控股")
    #expect(snap.fundamentals["总市值"] == "3.00万亿")
    #expect(snap.fundamentals["市场"] == "港股")
    #expect(snap.fundamentals["PE(TTM)"] == nil)   // "-" was dropped, not propagated as text
    #expect(snap.fundamentals["PB"] == nil)
    #expect(snap.fundamentals["ROE"] == nil)
}

@Test func eastmoney_degrades_gracefully_when_endpoints_fail() async throws {
    // Both endpoints return 404 (no handler matches). The provider should
    // still return a snapshot with `nil` lastPrice and an empty fundamentals
    // dictionary — not throw.
    let p = provider()
    EastMoneyMockURLProtocol.handlers = [:]   // 404 for everything
    defer { EastMoneyMockURLProtocol.handlers = [:] }

    let snap = try await p.snapshot(symbol: "600519.SS", asOf: Date())
    #expect(snap.symbol == "600519.SS")
    #expect(snap.lastPrice == nil)
    #expect(snap.news.isEmpty)
    // Even with no quote data the provider still labels the market.
    #expect(snap.fundamentals["市场"] == "沪市A股")
}

@Test func eastmoney_parses_kline_csv_into_bars() async throws {
    // Sanity check the CSV row parser handles realistic EastMoney rows. Use a
    // minimal 5-row series so we exercise parsing without enough data for
    // RSI/MACD (those degrade silently — Technicals helper returns "").
    let p = provider()
    EastMoneyMockURLProtocol.handlers = [
        "push2his.eastmoney.com/api/qt/stock/kline/get":
            kLineFixture(rows: [
                "2024-01-02,15.20,15.50,15.60,15.10,500000,7500000,3.3,2.0,0.30,0.5",
                "2024-01-03,15.55,15.30,15.70,15.20,400000,6100000,3.2,-1.3,-0.20,0.4",
                "2024-01-04,15.30,15.80,15.85,15.20,600000,9400000,4.2,3.3,0.50,0.6",
                "2024-01-05,15.85,15.95,16.10,15.70,550000,8700000,2.5,0.9,0.15,0.55",
                "2024-01-08,15.95,16.20,16.30,15.90,520000,8300000,2.5,1.6,0.25,0.5"
            ]),
        "push2delay.eastmoney.com/api/qt/stock/get":
            quoteFixture(["f43": 16.20, "f57": "000001", "f58": "平安银行"])
    ]
    defer { EastMoneyMockURLProtocol.handlers = [:] }

    let snap = try await p.snapshot(symbol: "000001.SZ", asOf: Date())
    #expect(snap.lastPrice == 16.20)
    #expect(snap.fundamentals["名称"] == "平安银行")
    #expect(snap.fundamentals["市场"] == "深市A股")
    // 52w range derived from the 5 bars we provided.
    #expect(snap.fundamentals["52周高低"] == "15.10 – 16.30")
}

}   // end EastMoneyProviderTests suite

/// Hits the real EastMoney endpoint. Off by default; run with
/// `EASTMONEY_LIVE=1 swift test --filter eastmoney_live` to exercise the
/// network path end-to-end. Useful as a one-shot sanity check that secid
/// formatting + URL host + JSON shapes are still in sync with production.
@Test(.disabled(if: ProcessInfo.processInfo.environment["EASTMONEY_LIVE"] == nil))
func eastmoney_live_smoke() async throws {
    let p = EastMoneyMarketDataProvider()   // real URLSession.shared

    let moutai = try await p.snapshot(symbol: "600519.SS", asOf: Date())
    print("[LIVE] 600519.SS lastPrice=\(moutai.lastPrice ?? -1) priceSummary=\(moutai.priceSummary) technicals=\(moutai.technicals) fundamentals=\(moutai.fundamentals)")
    #expect(moutai.lastPrice != nil)
    #expect(moutai.fundamentals["名称"] != nil)
    #expect(moutai.fundamentals["市场"] == "沪市A股")

    let tencent = try await p.snapshot(symbol: "0700.HK", asOf: Date())
    print("[LIVE] 0700.HK lastPrice=\(tencent.lastPrice ?? -1) fundamentals=\(tencent.fundamentals)")
    #expect(tencent.lastPrice != nil)
    #expect(tencent.fundamentals["市场"] == "港股")

    // Layer the financial decorator on top of the live base provider and
    // re-fetch to verify the merged dictionary picks up income-statement
    // fields from the real EastMoney F10 tables.
    let withFinancials = EastMoneyFinancialProvider(base: p)
    let moutaiFin = try await withFinancials.snapshot(symbol: "600519.SS", asOf: Date())
    print("[LIVE+FIN] 600519.SS fundamentals=\(moutaiFin.fundamentals)")
    #expect(moutaiFin.fundamentals["营业总收入"] != nil)
    #expect(moutaiFin.fundamentals["营收 YoY"] != nil)
    #expect(moutaiFin.fundamentals["报告期"] != nil)

    let tencentFin = try await withFinancials.snapshot(symbol: "0700.HK", asOf: Date())
    print("[LIVE+FIN] 0700.HK fundamentals=\(tencentFin.fundamentals)")
    #expect(tencentFin.fundamentals["营业收入"] != nil)
    #expect(tencentFin.fundamentals["毛利率"] != nil)
}

