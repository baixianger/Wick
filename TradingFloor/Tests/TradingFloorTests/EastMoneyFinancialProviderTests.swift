import Testing
import Foundation
@testable import TradingFloor

// MARK: - URLProtocol mock for the financial endpoints

final class FinancialMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handlers: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host.contains("eastmoney.com")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let key = "\(url.host ?? "")\(url.path)"
        guard let body = Self.handlers[key] else {
            let r = HTTPURLResponse(url: url, statusCode: 404,
                                     httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self); return
        }
        let r = HTTPURLResponse(url: url, statusCode: 200,
                                 httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [FinancialMockURLProtocol.self]
    return URLSession(configuration: c)
}

/// Stub base provider that supplies whatever the decorator should leave
/// alone (existing 总市值 + PE), plus the symbol the decorator routes on.
private struct PreloadedBaseProvider: MarketDataProvider {
    let fundamentals: [String: String]
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        MarketSnapshot(symbol: symbol, asOf: asOf, lastPrice: 100,
                       priceSummary: "+1%", technicals: "RSI 50",
                       fundamentals: fundamentals, news: [])
    }
}

// MARK: - Fixtures

private func aShareFixture() -> Data {
    let payload: [String: Any] = [
        "result": ["data": [[
            "REPORTDATE": "2025-03-31 00:00:00",
            "QDATE": "2025Q1",
            "BASIC_EPS": 21.38,
            "TOTAL_OPERATE_INCOME": 51_443_450_583.77,
            "PARENT_NETPROFIT": 26_847_474_238.76,
            "WEIGHTAVG_ROE": 10.92,
            "YSTZ": 10.6673989111,
            "SJLTZ": 11.56,
            "BPS": 205.666530124802,
            "MGJYXJJE": 7.012586430561,
            "XSMLL": 91.9736093542
        ]]]
    ]
    return try! JSONSerialization.data(withJSONObject: payload)
}

private func hkFixture() -> Data {
    let payload: [String: Any] = [
        "result": ["data": [[
            "REPORT_TYPE": "2026年一季报",
            "STD_REPORT_DATE": "2026-03-31 00:00:00",
            "BASIC_EPS": 6.431,
            "OPERATE_INCOME": 196_458_000_000.0,
            "OPERATE_INCOME_YOY": 9.13,
            "HOLDER_PROFIT": 58_093_000_000.0,
            "HOLDER_PROFIT_YOY": 21.48,
            "GROSS_PROFIT_RATIO": 56.63,
            "NET_PROFIT_RATIO": 30.23,
            "ROE_AVG": 5.09,
            "ROE_YEARLY": 20.37,
            "DEBT_ASSET_RATIO": 40.94,
            "NETCASH_OPERATE": 101_351_000_000.0,
            "PER_NETCASH_OPERATE": 11.108
        ]]]
    ]
    return try! JSONSerialization.data(withJSONObject: payload)
}

private func failureFixture() -> Data {
    let payload: [String: Any] = ["result": NSNull(), "success": false, "message": "返回数据为空"]
    return try! JSONSerialization.data(withJSONObject: payload)
}

// MARK: - Tests
//
// Serialized because `FinancialMockURLProtocol.handlers` is shared state.

@Suite(.serialized)
struct EastMoneyFinancialProviderTests {

    private func provider(base: any MarketDataProvider) -> EastMoneyFinancialProvider {
        EastMoneyFinancialProvider(
            base: base,
            session: mockSession(),
            limiter: HTTPRateLimiter(minInterval: 0)
        )
    }

    @Test func ashare_merges_financial_fields_into_fundamentals() async throws {
        FinancialMockURLProtocol.handlers = [
            "datacenter-web.eastmoney.com/api/data/v1/get": aShareFixture()
        ]
        defer { FinancialMockURLProtocol.handlers = [:] }

        let base = PreloadedBaseProvider(fundamentals: [
            "总市值": "1.60万亿",     // existing — must not be overwritten
            "PE(TTM)": "14.6"
        ])
        let snap = try await provider(base: base).snapshot(
            symbol: "600519.SS", asOf: Date())

        // Existing keys preserved.
        #expect(snap.fundamentals["总市值"] == "1.60万亿")
        #expect(snap.fundamentals["PE(TTM)"] == "14.6")

        // New A-share fields populated.
        #expect(snap.fundamentals["报告期"] == "2025Q1")
        #expect(snap.fundamentals["营业总收入"] == "514.43亿")
        #expect(snap.fundamentals["归母净利润"] == "268.47亿")
        #expect(snap.fundamentals["营收 YoY"] == "+10.67%")
        #expect(snap.fundamentals["净利 YoY"] == "+11.56%")
        #expect(snap.fundamentals["毛利率"] == "+91.97%")
        #expect(snap.fundamentals["加权 ROE"] == "+10.92%")
        #expect(snap.fundamentals["EPS"] == "21.38")
    }

    @Test func hk_merges_financial_fields_into_fundamentals() async throws {
        FinancialMockURLProtocol.handlers = [
            "datacenter.eastmoney.com/securities/api/data/v1/get": hkFixture()
        ]
        defer { FinancialMockURLProtocol.handlers = [:] }

        let snap = try await provider(base: PreloadedBaseProvider(fundamentals: [:]))
            .snapshot(symbol: "0700.HK", asOf: Date())

        #expect(snap.fundamentals["报告期"] == "2026年一季报")
        #expect(snap.fundamentals["营业收入"] == "1964.58亿")
        #expect(snap.fundamentals["营收 YoY"] == "+9.13%")
        #expect(snap.fundamentals["归母净利润"] == "580.93亿")
        #expect(snap.fundamentals["毛利率"] == "+56.63%")
        #expect(snap.fundamentals["净利率"] == "+30.23%")
        #expect(snap.fundamentals["ROE"] == "+5.09%")
        #expect(snap.fundamentals["资产负债率"] == "+40.94%")
        #expect(snap.fundamentals["经营现金流"] == "1013.51亿")
    }

    @Test func non_cn_symbol_passes_through_unchanged() async throws {
        FinancialMockURLProtocol.handlers = [
            "datacenter-web.eastmoney.com/api/data/v1/get": aShareFixture()
        ]
        defer { FinancialMockURLProtocol.handlers = [:] }

        let base = PreloadedBaseProvider(fundamentals: ["P/E": "31.2"])
        let snap = try await provider(base: base).snapshot(
            symbol: "NVDA", asOf: Date())

        // Decorator must not have called the endpoint or mutated base output.
        #expect(snap.fundamentals == ["P/E": "31.2"])
        #expect(snap.fundamentals["营收 YoY"] == nil)
        #expect(snap.fundamentals["报告期"] == nil)
    }

    @Test func failed_fetch_keeps_base_snapshot() async throws {
        FinancialMockURLProtocol.handlers = [
            // Successful HTTP, but `success: false` body — decorator must
            // gracefully fall back to the base snapshot rather than throw.
            "datacenter-web.eastmoney.com/api/data/v1/get": failureFixture()
        ]
        defer { FinancialMockURLProtocol.handlers = [:] }

        let base = PreloadedBaseProvider(fundamentals: ["市场": "沪市A股"])
        let snap = try await provider(base: base).snapshot(
            symbol: "600519.SS", asOf: Date())

        #expect(snap.fundamentals == ["市场": "沪市A股"])
    }
}
