import Testing
import Foundation
@testable import TradingFloor

// MARK: - URLProtocol mock for the CCASS mutualmarket page

final class CCASSMockURLProtocol: URLProtocol, @unchecked Sendable {
    /// Full HTML body to serve, or `nil` to simulate an endpoint failure
    /// (non-2xx). Set per-test.
    nonisolated(unsafe) static var html: String?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.contains("mutualmarket") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        guard let html = Self.html else {
            let resp = HTTPURLResponse(url: url, statusCode: 503,
                                       httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [CCASSMockURLProtocol.self]
    return URLSession(configuration: cfg)
}

private struct StubBase: MarketDataProvider {
    var fundamentals: [String: String] = [:]
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        MarketSnapshot(symbol: symbol, asOf: asOf, fundamentals: fundamentals)
    }
}

/// A date inside the Q1-2026 window so the recency guard passes for a
/// `2026/03/31` shareholding date.
private func asOfQ1() -> Date {
    var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 1
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

/// Real captured CCASS `mutualmarket.aspx?t=sh` markup (trimmed to a few
/// rows): the `<h2 class="ccass-heading">` shareholding-date header plus
/// three datarows. Note the A-share code lives in the *name* cell as
/// `(A #NNNNNN)`; `col-stock-code` carries HKEX's internal Connect code.
private func fixtureHTML(date: String = "2026/03/31") -> String {
    """
    <h2 class="ccass-heading">
    <span style="text-decoration:underline;">Shareholding Date: \(date)</span>
    </h2>
    <table class="search-result-table">
    <tr>
    <td class="col-stock-code">
    <div class="mobile-list-heading">Stock Code:</div>
    <div class="mobile-list-body">90519</div>
    </td>
    <td class="col-stock-name">
    <div class="mobile-list-heading">Name:</div>
    <div class="mobile-list-body">KWEICHOW MOUTAI CO.,LTD. (A #600519)</div>
    </td>
    <td class="col-shareholding">
    <div class="mobile-list-heading">Shareholding in CCASS:</div>
    <div class="mobile-list-body">58,733,069</div>
    </td>
    <td class="col-shareholding-percent">
    <div class="mobile-list-heading">% of the total number of securities listed and traded on the SSE:</div>
    <div class="mobile-list-body">4.69%</div>
    </td>
    </tr>
    <tr>
    <td class="col-stock-code">
    <div class="mobile-list-heading">Stock Code:</div>
    <div class="mobile-list-body">90036</div>
    </td>
    <td class="col-stock-name">
    <div class="mobile-list-heading">Name:</div>
    <div class="mobile-list-body">CHINA MERCHANTS BANK CO.,LIMITED (A #600036)</div>
    </td>
    <td class="col-shareholding">
    <div class="mobile-list-heading">Shareholding in CCASS:</div>
    <div class="mobile-list-body">1,197,896,736</div>
    </td>
    <td class="col-shareholding-percent">
    <div class="mobile-list-heading">% of the total number of securities listed and traded on the SSE:</div>
    <div class="mobile-list-body">5.80%</div>
    </td>
    </tr>
    </table>
    """
}

// MARK: - Tests

@Suite(.serialized)
struct CCASSNorthboundDecoratorTests {

    @Test func renders_northbound_holding_with_quarter_label() async throws {
        CCASSMockURLProtocol.html = fixtureHTML()
        defer { CCASSMockURLProtocol.html = nil }

        let dec = CCASSNorthboundDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: asOfQ1())
        let line = s.fundamentals["北向持股"]
        #expect(line != nil)
        // 58,733,069 shares → 5873万股; 4.69% passed through; quarter label.
        #expect(line == "4.69% 流通股 (5873万股, 截至 2026Q1)")
    }

    @Test func bigshares_uses_yi_bucket_for_large_holdings() async throws {
        CCASSMockURLProtocol.html = fixtureHTML()
        defer { CCASSMockURLProtocol.html = nil }

        let dec = CCASSNorthboundDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600036.SS", asOf: asOfQ1())
        // 1,197,896,736 shares → 11.98亿股; 5.80%.
        #expect(s.fundamentals["北向持股"] == "5.80% 流通股 (11.98亿股, 截至 2026Q1)")
    }

    @Test func skips_hk_and_non_cn_tickers() async throws {
        CCASSMockURLProtocol.html = fixtureHTML()
        defer { CCASSMockURLProtocol.html = nil }

        let dec = CCASSNorthboundDecorator(base: StubBase(), session: mockSession())
        for symbol in ["0700.HK", "NVDA"] {
            let s = try await dec.snapshot(symbol: symbol, asOf: asOfQ1())
            #expect(s.fundamentals["北向持股"] == nil, "should skip \(symbol)")
        }
    }

    @Test func stock_absent_from_list_adds_no_key() async throws {
        CCASSMockURLProtocol.html = fixtureHTML()
        defer { CCASSMockURLProtocol.html = nil }

        // 000001.SZ isn't in the Shanghai fixture (and its market routes to
        // the SZ list, which the mock also serves — but the code isn't present).
        let dec = CCASSNorthboundDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "000001.SZ", asOf: asOfQ1())
        #expect(s.fundamentals["北向持股"] == nil)
    }

    @Test func endpoint_failure_leaves_fundamentals_untouched() async throws {
        CCASSMockURLProtocol.html = nil   // 503
        let dec = CCASSNorthboundDecorator(
            base: StubBase(fundamentals: ["报告期": "2026Q1"]), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: asOfQ1())
        #expect(s.fundamentals["北向持股"] == nil)
        #expect(s.fundamentals["报告期"] == "2026Q1")   // pass-through intact
    }

    @Test func does_not_overwrite_existing_key() async throws {
        CCASSMockURLProtocol.html = fixtureHTML()
        defer { CCASSMockURLProtocol.html = nil }

        let dec = CCASSNorthboundDecorator(
            base: StubBase(fundamentals: ["北向持股": "pre-existing"]),
            session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: asOfQ1())
        #expect(s.fundamentals["北向持股"] == "pre-existing")
    }

    @Test func quarter_cache_serves_second_ticker_without_refetch() async throws {
        CCASSMockURLProtocol.html = fixtureHTML()
        let dec = CCASSNorthboundDecorator(base: StubBase(), session: mockSession())

        let first = try await dec.snapshot(symbol: "600519.SS", asOf: asOfQ1())
        #expect(first.fundamentals["北向持股"] != nil)

        // Endpoint "down" — a second Shanghai ticker must still resolve from
        // the cached quarter list (one fetch serves the whole market).
        CCASSMockURLProtocol.html = nil
        let second = try await dec.snapshot(symbol: "600036.SS", asOf: asOfQ1())
        #expect(second.fundamentals["北向持股"] == "5.80% 流通股 (11.98亿股, 截至 2026Q1)")
    }

    @Test func recency_guard_drops_stale_quarter() async throws {
        // A year-old shareholding date: the guard must render nothing rather
        // than surface a stale figure (CCASS could freeze like the daily
        // tables did in 2024).
        CCASSMockURLProtocol.html = fixtureHTML(date: "2025/03/31")
        defer { CCASSMockURLProtocol.html = nil }

        let dec = CCASSNorthboundDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: asOfQ1())
        #expect(s.fundamentals["北向持股"] == nil)
    }

    @Test func quarter_label_derivation() {
        func d(_ s: String) -> Date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy/MM/dd"
            return f.date(from: s)!
        }
        #expect(CCASSNorthboundDecorator.quarterLabel(d("2026/03/31")) == "2026Q1")
        #expect(CCASSNorthboundDecorator.quarterLabel(d("2026/06/30")) == "2026Q2")
        #expect(CCASSNorthboundDecorator.quarterLabel(d("2025/09/30")) == "2025Q3")
        #expect(CCASSNorthboundDecorator.quarterLabel(d("2025/12/31")) == "2025Q4")
    }
}

// MARK: - Live smoke (disabled unless CCASS_LIVE is set)

@Test(.disabled(if: ProcessInfo.processInfo.environment["CCASS_LIVE"] == nil))
func ccass_northbound_live_smoke() async throws {
    struct EmptyBase: MarketDataProvider {
        func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
            MarketSnapshot(symbol: symbol, asOf: asOf)
        }
    }
    let dec = CCASSNorthboundDecorator(base: EmptyBase())
    let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
    print("[LIVE-CCASS] 北向持股 = \(s.fundamentals["北向持股"] ?? "nil")")
    #expect(s.fundamentals["北向持股"]?.contains("流通股") == true)
}
