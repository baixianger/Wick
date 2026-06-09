import Testing
import Foundation
@testable import TradingFloor

// MARK: - URLProtocol mock for the slist endpoint

final class BoardMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var diff: [[String: Any]]?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.contains("slist") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let payload: [String: Any] = Self.diff.map {
            ["data": ["total": $0.count, "diff": $0]]
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
    cfg.protocolClasses = [BoardMockURLProtocol.self]
    return URLSession(configuration: cfg)
}

private struct StubBase: MarketDataProvider {
    var macro: String = ""
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        MarketSnapshot(symbol: symbol, asOf: asOf,
                       priceSummary: "", technicals: "",
                       fundamentals: [:], news: [], macro: macro)
    }
}

/// Real shape from the probe: industry first, then tiers, themes, and the
/// index-membership noise the decorator must filter.
private func seedBoards() {
    BoardMockURLProtocol.diff = [
        ["f12": "BK0438", "f14": "食品饮料", "f3": -0.22],
        ["f12": "BK1575", "f14": "白酒Ⅲ",   "f3": -2.35],
        ["f12": "BK1277", "f14": "白酒Ⅱ",   "f3": -2.35],   // tier dupe → dropped
        ["f12": "BK0500", "f14": "HS300_",  "f3": 1.3],     // underscore → dropped
        ["f12": "BK0596", "f14": "融资融券", "f3": 1.43],    // denylist → dropped
        ["f12": "BK0173", "f14": "贵州板块", "f3": 1.5],
        ["f12": "BK0477", "f14": "酿酒概念", "f3": -1.58],
        ["f12": "BK0552", "f14": "机构重仓", "f3": 1.0],     // over maxBoards anyway
    ]
}

// MARK: - Tests

@Suite(.serialized)
struct BoardContextDecoratorTests {

    @Test func renders_filtered_deduped_board_line() async throws {
        seedBoards()
        defer { BoardMockURLProtocol.diff = nil }

        let dec = BoardContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.macro == "所属板块 食品饮料 -0.2%; 白酒Ⅲ -2.4%; 贵州板块 +1.5%; 酿酒概念 -1.6%")
    }

    @Test func skips_non_cn_tickers() async throws {
        seedBoards()
        defer { BoardMockURLProtocol.diff = nil }

        let dec = BoardContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "NVDA", asOf: Date())
        #expect(s.macro.isEmpty)
    }

    @Test func appends_to_existing_macro_with_newline() async throws {
        seedBoards()
        defer { BoardMockURLProtocol.diff = nil }

        let dec = BoardContextDecorator(base: StubBase(macro: "CPI YoY +1.2%"),
                                        session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.macro.hasPrefix("CPI YoY +1.2%\n所属板块"))
    }

    @Test func endpoint_failure_leaves_macro_untouched() async throws {
        BoardMockURLProtocol.diff = nil
        let dec = BoardContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.macro.isEmpty)
    }

    @Test func all_noise_boards_yield_no_line() async throws {
        BoardMockURLProtocol.diff = [
            ["f12": "BK0500", "f14": "HS300_",  "f3": 1.3],
            ["f12": "BK0596", "f14": "融资融券", "f3": 1.43],
        ]
        defer { BoardMockURLProtocol.diff = nil }

        let dec = BoardContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.macro.isEmpty)
    }

    @Test func cache_serves_same_symbol_same_day() async throws {
        seedBoards()
        let dec = BoardContextDecorator(base: StubBase(), session: mockSession())
        let day = Date()
        let first = try await dec.snapshot(symbol: "600519.SS", asOf: day)
        #expect(first.macro.contains("所属板块"))

        BoardMockURLProtocol.diff = nil   // endpoint "down" — cache serves
        let second = try await dec.snapshot(symbol: "600519.SS", asOf: day)
        #expect(second.macro.contains("所属板块"))
    }
}

// MARK: - Live smoke

@Test(.disabled(if: ProcessInfo.processInfo.environment["EASTMONEY_LIVE"] == nil))
func board_context_live_smoke() async throws {
    struct EmptyBase: MarketDataProvider {
        func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
            MarketSnapshot(symbol: symbol, asOf: asOf)
        }
    }
    let dec = BoardContextDecorator(base: EmptyBase())
    let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
    print("[LIVE-BOARD] \(s.macro)")
    #expect(s.macro.contains("所属板块"))

    let hk = try await dec.snapshot(symbol: "0700.HK", asOf: Date())
    print("[LIVE-BOARD-HK] \(hk.macro)")
    #expect(hk.macro.contains("所属板块"))
}
