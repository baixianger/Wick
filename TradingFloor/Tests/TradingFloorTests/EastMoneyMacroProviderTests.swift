import Testing
import Foundation
@testable import TradingFloor

// MARK: - URLProtocol mock (route any datacenter-web.eastmoney.com call)

final class EMMacroMockURLProtocol: URLProtocol, @unchecked Sendable {
    /// reportName → JSON body
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
        let report = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "reportName" })?.value ?? ""
        let body = Self.handlers[report] ?? Self.emptyResponse()
        let r = HTTPURLResponse(url: url, statusCode: 200,
                                 httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func emptyResponse() -> Data {
        let p: [String: Any] = ["result": NSNull(), "success": false]
        return try! JSONSerialization.data(withJSONObject: p)
    }
    static func valueResponse(field: String, value: Double) -> Data {
        let p: [String: Any] = [
            "result": ["data": [["REPORT_DATE": "2026-04-01 00:00:00", field: value]]],
            "success": true
        ]
        return try! JSONSerialization.data(withJSONObject: p)
    }
}

private func mockClient() -> EastMoneyMacroClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [EMMacroMockURLProtocol.self]
    return EastMoneyMacroClient(session: URLSession(configuration: cfg))
}

private struct StubBase: MarketDataProvider {
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        MarketSnapshot(symbol: symbol, asOf: asOf,
                       priceSummary: "", technicals: "",
                       fundamentals: [:], news: [], macro: "")
    }
}

// MARK: - Tests

@Suite(.serialized)
struct EastMoneyMacroProviderTests {

    @Test func macro_summary_renders_all_known_series() async {
        EMMacroMockURLProtocol.handlers = [
            "RPT_ECONOMY_CPI": EMMacroMockURLProtocol.valueResponse(field: "NATIONAL_SAME", value: 1.2),
            "RPT_ECONOMY_PPI": EMMacroMockURLProtocol.valueResponse(field: "BASE_SAME", value: -2.8),
            "RPT_ECONOMY_PMI": EMMacroMockURLProtocol.valueResponse(field: "MAKE_INDEX", value: 50.3),
            // PMI services maps to the same endpoint with NMAKE_INDEX, but
            // the mock returns whatever single field we seeded under the
            // report name — both PMI calls hit the same row, so seed an
            // object that has BOTH fields:
            "RPT_ECONOMY_CURRENCY_SUPPLY": EMMacroMockURLProtocol.valueResponse(field: "BASIC_CURRENCY_SAME", value: 8.6),
            "RPT_ECONOMY_RMB_LOAN": EMMacroMockURLProtocol.valueResponse(field: "LOAN_ACCUMULATE_SAME", value: -13.1),
        ]
        // Replace PMI fixture with one that carries both MAKE_INDEX +
        // NMAKE_INDEX so the two PMI fetches each find their field.
        let pmiBoth: [String: Any] = [
            "result": ["data": [[
                "REPORT_DATE": "2026-04-01 00:00:00",
                "MAKE_INDEX": 50.3,
                "NMAKE_INDEX": 49.4
            ]]],
            "success": true
        ]
        EMMacroMockURLProtocol.handlers["RPT_ECONOMY_PMI"] =
            try! JSONSerialization.data(withJSONObject: pmiBoth)

        defer { EMMacroMockURLProtocol.handlers = [:] }

        let summary = await mockClient().macroSummary()
        #expect(summary.contains("CPI YoY +1.2%"))
        #expect(summary.contains("PPI YoY -2.8%"))
        #expect(summary.contains("PMI 制造业 50.3"))
        #expect(summary.contains("PMI 服务业 49.4"))
        #expect(summary.contains("M2 YoY +8.6%"))
        #expect(summary.contains("人民币贷款累计 YoY -13.1%"))
    }

    @Test func macro_summary_drops_failed_series_silently() async {
        // Only CPI returns a value; the others either 404 (we don't
        // register a handler so the mock returns an empty 200 body)
        // or aren't seeded. The summary should still surface CPI and
        // not blow up on the missing rows.
        EMMacroMockURLProtocol.handlers = [
            "RPT_ECONOMY_CPI": EMMacroMockURLProtocol.valueResponse(
                field: "NATIONAL_SAME", value: 1.2),
        ]
        defer { EMMacroMockURLProtocol.handlers = [:] }

        let summary = await mockClient().macroSummary()
        #expect(summary == "CPI YoY +1.2%")
    }

    @Test func provider_fills_macro_for_cn_symbol_only() async throws {
        EMMacroMockURLProtocol.handlers = [
            "RPT_ECONOMY_CPI": EMMacroMockURLProtocol.valueResponse(
                field: "NATIONAL_SAME", value: 1.2),
        ]
        defer { EMMacroMockURLProtocol.handlers = [:] }

        let provider = EastMoneyMacroProvider(base: StubBase(),
                                              client: mockClient())

        // CN ticker → macro populated.
        let cn = try await provider.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(cn.macro.contains("CPI YoY +1.2%"))

        // US ticker → macro stays empty (the EM decorator skipped it,
        // leaving the slot for FRED elsewhere in the chain).
        let us = try await provider.snapshot(symbol: "NVDA", asOf: Date())
        #expect(us.macro.isEmpty)
    }

    @Test func provider_caches_macro_per_day() async throws {
        // Two consecutive calls with the same `asOf` must share one
        // network round. We can't directly count HTTP calls without
        // wrapping URLProtocol, so we verify the cached value persists
        // even after the handler is wiped: the cache served the
        // second call from memory.
        EMMacroMockURLProtocol.handlers = [
            "RPT_ECONOMY_CPI": EMMacroMockURLProtocol.valueResponse(
                field: "NATIONAL_SAME", value: 1.2),
        ]
        let provider = EastMoneyMacroProvider(base: StubBase(),
                                              client: mockClient())
        let day = Date()
        let first = try await provider.snapshot(symbol: "600519.SS", asOf: day)
        #expect(first.macro.contains("+1.2%"))

        EMMacroMockURLProtocol.handlers = [:]   // wipe — cache must serve.
        let second = try await provider.snapshot(symbol: "000001.SZ", asOf: day)
        #expect(second.macro.contains("+1.2%"))
    }
}

// MARK: - Live smoke (off by default)

/// Run with `EASTMONEY_LIVE=1 swift test --filter eastmoney_macro_live`
/// to hit real EastMoney datacenter endpoints. Useful as a one-shot
/// sanity check that the reportNames + field paths still match
/// production after a schema change.
@Test(.disabled(if: ProcessInfo.processInfo.environment["EASTMONEY_LIVE"] == nil))
func eastmoney_macro_live_smoke() async {
    let summary = await EastMoneyMacroClient().macroSummary()
    print("[LIVE-MACRO] \(summary)")
    // We can't assert on specific values (CPI moves every release) —
    // just that we got SOMETHING back. If the summary is empty all
    // five endpoints failed simultaneously, which is the kind of
    // schema drift we want to notice.
    #expect(!summary.isEmpty)
}
