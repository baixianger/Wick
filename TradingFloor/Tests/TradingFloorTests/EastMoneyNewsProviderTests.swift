import Testing
import Foundation
@testable import TradingFloor

// MARK: - URLProtocol mock for the two news endpoints

final class CNNewsMockURLProtocol: URLProtocol, @unchecked Sendable {
    /// Body served for the article-search endpoint (already JSONP-wrapped
    /// when the test wants to exercise the unwrap path).
    nonisolated(unsafe) static var searchBody: String?
    /// Body served for the announcement endpoint.
    nonisolated(unsafe) static var annBody: String?

    override class func canInit(with request: URLRequest) -> Bool {
        let host = request.url?.host ?? ""
        return host.contains("search-api-web.eastmoney.com")
            || host.contains("np-anotice-stock.eastmoney.com")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let body = url.host?.contains("search-api-web") == true
            ? Self.searchBody : Self.annBody
        guard let body else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [CNNewsMockURLProtocol.self]
    return URLSession(configuration: cfg)
}

private struct StubBase: MarketDataProvider {
    var presetNews: [String] = []
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        MarketSnapshot(symbol: symbol, asOf: asOf,
                       priceSummary: "", technicals: "",
                       fundamentals: [:], news: presetNews, macro: "")
    }
}

private func seedBoth() {
    CNNewsMockURLProtocol.searchBody = """
    ({"code":0,"result":{"cmsArticleWebOld":[
      {"date":"2026-06-09 16:36:00","title":"白酒概念下跌1.10%","mediaName":"证券时报网","content":"…","url":"http://x"},
      {"date":"2026-06-03 11:01:00","title":"贵州茅台跌破1300元/股整数关口","mediaName":"人民财讯","content":"…","url":"http://y"}
    ]}})
    """
    CNNewsMockURLProtocol.annBody = """
    {"data":{"list":[
      {"title_ch":"贵州茅台:2025年度股东会会议资料","notice_date":"2026-06-03 00:00:00"},
      {"title":"贵州茅台:关于回购股份的进展公告","notice_date":"2026-06-02 00:00:00"}
    ]}}
    """
}

private func clearMock() {
    CNNewsMockURLProtocol.searchBody = nil
    CNNewsMockURLProtocol.annBody = nil
}

// MARK: - Tests

@Suite(.serialized)
struct EastMoneyNewsProviderTests {

    @Test func fills_news_with_articles_and_filings() async throws {
        seedBoth()
        defer { clearMock() }

        let p = EastMoneyNewsProvider(base: StubBase(), session: mockSession())
        let s = try await p.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.news.count == 4)
        // Articles first, dates shortened, media attributed.
        #expect(s.news[0] == "[06-09] 白酒概念下跌1.10% — 证券时报网")
        #expect(s.news[1] == "[06-03] 贵州茅台跌破1300元/股整数关口 — 人民财讯")
        // Filings tagged 公告; `title_ch` preferred, `title` fallback works.
        #expect(s.news[2] == "[公告 06-03] 贵州茅台:2025年度股东会会议资料")
        #expect(s.news[3] == "[公告 06-02] 贵州茅台:关于回购股份的进展公告")
    }

    @Test func skips_non_cn_tickers() async throws {
        seedBoth()
        defer { clearMock() }

        let p = EastMoneyNewsProvider(base: StubBase(), session: mockSession())
        let s = try await p.snapshot(symbol: "NVDA", asOf: Date())
        #expect(s.news.isEmpty)
    }

    @Test func does_not_overwrite_existing_news() async throws {
        seedBoth()
        defer { clearMock() }

        let p = EastMoneyNewsProvider(base: StubBase(presetNews: ["already here"]),
                                      session: mockSession())
        let s = try await p.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.news == ["already here"])
    }

    @Test func one_stream_failing_keeps_the_other() async throws {
        seedBoth()
        CNNewsMockURLProtocol.searchBody = nil   // articles endpoint down
        defer { clearMock() }

        let p = EastMoneyNewsProvider(base: StubBase(), session: mockSession())
        let s = try await p.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.news.count == 2)
        #expect(s.news.allSatisfy { $0.hasPrefix("[公告") })
    }

    @Test func both_streams_failing_leaves_news_empty() async throws {
        clearMock()
        let p = EastMoneyNewsProvider(base: StubBase(), session: mockSession())
        let s = try await p.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.news.isEmpty)
    }

    @Test func cache_serves_same_symbol_same_day() async throws {
        seedBoth()
        let p = EastMoneyNewsProvider(base: StubBase(), session: mockSession())
        let day = Date()
        let first = try await p.snapshot(symbol: "600519.SS", asOf: day)
        #expect(first.news.count == 4)

        clearMock()   // endpoints "down" — cache must serve
        let second = try await p.snapshot(symbol: "600519.SS", asOf: day)
        #expect(second.news.count == 4)
    }
}

// MARK: - Live smoke

@Test(.disabled(if: ProcessInfo.processInfo.environment["EASTMONEY_LIVE"] == nil))
func cn_news_live_smoke() async throws {
    struct EmptyBase: MarketDataProvider {
        func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
            MarketSnapshot(symbol: symbol, asOf: asOf)
        }
    }
    let p = EastMoneyNewsProvider(base: EmptyBase())
    let s = try await p.snapshot(symbol: "600519.SS", asOf: Date())
    print("[LIVE-NEWS]\n" + s.news.joined(separator: "\n"))
    #expect(!s.news.isEmpty, "expected at least one news/filing line")

    let hk = try await p.snapshot(symbol: "0700.HK", asOf: Date())
    print("[LIVE-NEWS-HK]\n" + hk.news.joined(separator: "\n"))
    #expect(!hk.news.isEmpty, "expected HK news/filing lines")
}
