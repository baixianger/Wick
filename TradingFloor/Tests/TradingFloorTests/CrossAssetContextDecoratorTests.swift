import Testing
import Foundation
@testable import TradingFloor

// MARK: - URLProtocol mock for query1.finance.yahoo.com

final class XAssetMockURLProtocol: URLProtocol, @unchecked Sendable {
    /// symbol → meta dict (matches Yahoo's chart.meta shape)
    nonisolated(unsafe) static var symbols: [String: [String: Any]] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.contains("yahoo.com") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let sym = url.lastPathComponent
        let payload: [String: Any]
        if let meta = Self.symbols[sym] {
            payload = ["chart": ["result": [["meta": meta]]]]
        } else {
            payload = ["chart": ["result": NSNull()]]
        }
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
    cfg.protocolClasses = [XAssetMockURLProtocol.self]
    return URLSession(configuration: cfg)
}

private struct StubBase: MarketDataProvider {
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        MarketSnapshot(symbol: symbol, asOf: asOf,
                       priceSummary: "", technicals: "",
                       fundamentals: [:], news: [], macro: "")
    }
}

private func seedAll() {
    XAssetMockURLProtocol.symbols = [
        "CL=F":     ["regularMarketPrice": 88.53,  "chartPreviousClose": 88.90],
        "GC=F":     ["regularMarketPrice": 4527.30,"chartPreviousClose": 4532.40],
        "BTC-USD":  ["regularMarketPrice": 73749.0,"chartPreviousClose": 74332.94],
        "DX-Y.NYB": ["regularMarketPrice": 98.998, "chartPreviousClose": 99.206],
        "^VIX":     ["regularMarketPrice": 15.74,  "chartPreviousClose": 16.29]
    ]
}

// MARK: - Tests

@Suite(.serialized)
struct CrossAssetContextDecoratorTests {

    @Test func renders_all_five_assets() async throws {
        seedAll()
        defer { XAssetMockURLProtocol.symbols = [:] }

        let dec = CrossAssetContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "NVDA", asOf: Date())
        // All five labels present.
        for label in ["WTI", "Gold", "BTC", "DXY", "VIX"] {
            #expect(s.macro.contains(label), "expected \(label) in macro: \(s.macro)")
        }
        // Day-change percents present.
        #expect(s.macro.contains("-0.4%"))      // WTI
        #expect(s.macro.contains("-3.4%"))      // VIX
        // Currency prefix for the dollar-denominated legs.
        #expect(s.macro.contains("$88.53"))      // WTI price
        #expect(s.macro.contains("$73,749"))     // BTC with thousands separator
    }

    @Test func partial_failure_drops_only_the_failed_leg() async throws {
        // Only WTI + BTC seeded — others should silently fall out of
        // the line; the line itself still surfaces.
        XAssetMockURLProtocol.symbols = [
            "CL=F":    ["regularMarketPrice": 88.53,  "chartPreviousClose": 88.90],
            "BTC-USD": ["regularMarketPrice": 73749.0,"chartPreviousClose": 74332.94]
        ]
        defer { XAssetMockURLProtocol.symbols = [:] }

        let dec = CrossAssetContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "NVDA", asOf: Date())
        #expect(s.macro.contains("WTI"))
        #expect(s.macro.contains("BTC"))
        #expect(!s.macro.contains("Gold"))
        #expect(!s.macro.contains("DXY"))
        #expect(!s.macro.contains("VIX"))
    }

    @Test func total_failure_leaves_macro_untouched() async throws {
        XAssetMockURLProtocol.symbols = [:]
        let dec = CrossAssetContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "NVDA", asOf: Date())
        #expect(s.macro.isEmpty)
    }

    @Test func appends_to_existing_macro_with_newline() async throws {
        seedAll()
        defer { XAssetMockURLProtocol.symbols = [:] }

        struct Preloaded: MarketDataProvider {
            func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
                MarketSnapshot(symbol: symbol, asOf: asOf,
                               priceSummary: "", technicals: "",
                               fundamentals: [:], news: [],
                               macro: "CPI YoY +1.2%")
            }
        }
        let dec = CrossAssetContextDecorator(base: Preloaded(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.macro.contains("CPI YoY"))    // preserved
        #expect(s.macro.contains("跨资产"))      // appended
        #expect(s.macro.split(separator: "\n").count == 2)
    }

    @Test func basket_cache_serves_second_ticker_on_same_day() async throws {
        seedAll()
        let dec = CrossAssetContextDecorator(base: StubBase(), session: mockSession())
        let day = Date()
        let first = try await dec.snapshot(symbol: "NVDA", asOf: day)
        #expect(first.macro.contains("WTI"))

        // Wipe the mock — cache must serve.
        XAssetMockURLProtocol.symbols = [:]
        let second = try await dec.snapshot(symbol: "600519.SS", asOf: day)
        #expect(second.macro.contains("WTI"))   // from cache
    }
}

// MARK: - Live smoke

@Test(.disabled(if: ProcessInfo.processInfo.environment["EASTMONEY_LIVE"] == nil))
func cross_asset_live_smoke() async throws {
    let dec = CrossAssetContextDecorator(base: StubMarketDataProvider())
    let s = try await dec.snapshot(symbol: "NVDA", asOf: Date())
    print("[LIVE-XA] \(s.macro)")
    // We can't assert exact prices but the basket should be non-empty
    // and contain at least 3 of 5 labels (Yahoo occasionally rate-limits
    // individual symbols).
    let labels = ["WTI", "Gold", "BTC", "DXY", "VIX"]
    let hits = labels.filter { s.macro.contains($0) }.count
    #expect(hits >= 3, "expected at least 3 of \(labels), got macro=\(s.macro)")
}
