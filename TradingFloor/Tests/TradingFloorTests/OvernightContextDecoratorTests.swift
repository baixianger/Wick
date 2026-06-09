import Testing
import Foundation
@testable import TradingFloor

// MARK: - URLProtocol mock for query1.finance.yahoo.com

final class OvernightMockURLProtocol: URLProtocol, @unchecked Sendable {
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
    cfg.protocolClasses = [OvernightMockURLProtocol.self]
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
    OvernightMockURLProtocol.symbols = [
        "^GSPC":    ["regularMarketPrice": 7386.65,  "chartPreviousClose": 7405.73],
        "^IXIC":    ["regularMarketPrice": 25678.82, "chartPreviousClose": 25929.66],
        "^HXC":     ["regularMarketPrice": 6298.65,  "chartPreviousClose": 6323.38],
        "XIN9.FGI": ["regularMarketPrice": 15561.99, "chartPreviousClose": 15373.72],
        "CNH=X":    ["regularMarketPrice": 6.7776,   "chartPreviousClose": 6.7815],
        "^TNX":     ["regularMarketPrice": 4.528,    "chartPreviousClose": 4.552]
    ]
}

// MARK: - Tests

@Suite(.serialized)
struct OvernightContextDecoratorTests {

    @Test func renders_all_six_legs_for_cn_ticker() async throws {
        seedAll()
        defer { OvernightMockURLProtocol.symbols = [:] }

        let dec = OvernightContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.macro.contains("隔夜外盘"))
        for label in ["标普500", "纳斯达克", "金龙中国", "富时A50", "离岸人民币", "美债10Y"] {
            #expect(s.macro.contains(label), "expected \(label) in macro: \(s.macro)")
        }
        // Index prices get thousands separators; FX keeps 4 decimals.
        #expect(s.macro.contains("7,387"))       // S&P 500
        #expect(s.macro.contains("6.7776"))      // USD/CNH
        // Yield renders in percent with a basis-point day change.
        #expect(s.macro.contains("4.53%"))
        #expect(s.macro.contains("-2.4bp"))
        // A50 day change positive.
        #expect(s.macro.contains("+1.2%"))
    }

    @Test func skips_non_cn_tickers_entirely() async throws {
        seedAll()
        defer { OvernightMockURLProtocol.symbols = [:] }

        let dec = OvernightContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "NVDA", asOf: Date())
        #expect(s.macro.isEmpty)
    }

    @Test func applies_to_hk_tickers() async throws {
        seedAll()
        defer { OvernightMockURLProtocol.symbols = [:] }

        let dec = OvernightContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "0700.HK", asOf: Date())
        #expect(s.macro.contains("隔夜外盘"))
    }

    @Test func partial_failure_drops_only_the_failed_leg() async throws {
        OvernightMockURLProtocol.symbols = [
            "^GSPC": ["regularMarketPrice": 7386.65, "chartPreviousClose": 7405.73],
            "CNH=X": ["regularMarketPrice": 6.7776,  "chartPreviousClose": 6.7815]
        ]
        defer { OvernightMockURLProtocol.symbols = [:] }

        let dec = OvernightContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.macro.contains("标普500"))
        #expect(s.macro.contains("离岸人民币"))
        #expect(!s.macro.contains("纳斯达克"))
        #expect(!s.macro.contains("金龙中国"))
        #expect(!s.macro.contains("富时A50"))
        #expect(!s.macro.contains("美债10Y"))
    }

    @Test func total_failure_leaves_macro_untouched() async throws {
        OvernightMockURLProtocol.symbols = [:]
        let dec = OvernightContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.macro.isEmpty)
    }

    @Test func appends_to_existing_macro_with_newline() async throws {
        seedAll()
        defer { OvernightMockURLProtocol.symbols = [:] }

        struct Preloaded: MarketDataProvider {
            func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
                MarketSnapshot(symbol: symbol, asOf: asOf,
                               priceSummary: "", technicals: "",
                               fundamentals: [:], news: [],
                               macro: "CPI YoY +1.2%")
            }
        }
        let dec = OvernightContextDecorator(base: Preloaded(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.macro.contains("CPI YoY"))    // preserved
        #expect(s.macro.contains("隔夜外盘"))    // appended
        #expect(s.macro.split(separator: "\n").count == 2)
    }

    @Test func basket_cache_serves_second_ticker_on_same_day() async throws {
        seedAll()
        let dec = OvernightContextDecorator(base: StubBase(), session: mockSession())
        let day = Date()
        let first = try await dec.snapshot(symbol: "600519.SS", asOf: day)
        #expect(first.macro.contains("标普500"))

        // Wipe the mock — cache must serve.
        OvernightMockURLProtocol.symbols = [:]
        let second = try await dec.snapshot(symbol: "000001.SZ", asOf: day)
        #expect(second.macro.contains("标普500"))   // from cache
    }
}

// MARK: - Live smoke

@Test(.disabled(if: ProcessInfo.processInfo.environment["EASTMONEY_LIVE"] == nil))
func overnight_context_live_smoke() async throws {
    let dec = OvernightContextDecorator(base: StubMarketDataProvider())
    let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
    print("[LIVE-ON] \(s.macro)")
    // Yahoo occasionally rate-limits individual symbols; require most legs.
    let labels = ["标普500", "纳斯达克", "金龙中国", "富时A50", "离岸人民币", "美债10Y"]
    let hits = labels.filter { s.macro.contains($0) }.count
    #expect(hits >= 4, "expected at least 4 of \(labels), got macro=\(s.macro)")
}
