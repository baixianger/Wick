import Testing
import Foundation
@testable import TradingFloor

// MARK: - Test doubles

/// Deterministic base provider — never touches the network.
private struct StubBase: MarketDataProvider {
    var presetNews: [String] = []
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        MarketSnapshot(symbol: symbol, asOf: asOf, news: presetNews)
    }
}

/// Mock scraper standing in for the WebKit-backed `BrowserSessionManager`.
/// Records whether `discussion(for:)` was actually invoked so the gating tests
/// can assert "the scraper was never even touched".
private actor MockScraper: XueqiuScraping {
    private var status: XueqiuSessionStatus
    private let lines: [String]
    private(set) var discussionCalls = 0

    init(status: XueqiuSessionStatus, lines: [String]) {
        self.status = status
        self.lines = lines
    }

    var sessionStatus: XueqiuSessionStatus { status }

    func discussion(for symbol: String) async -> [String] {
        discussionCalls += 1
        return lines
    }

    func wasCalled() -> Int { discussionCalls }
}

private func makeDecorator(
    enabled: Bool,
    status: XueqiuSessionStatus,
    lines: [String],
    presetNews: [String] = []
) -> (BYODiscussionNewsDecorator, MockScraper) {
    let scraper = MockScraper(status: status, lines: lines)
    let dec = BYODiscussionNewsDecorator(
        base: StubBase(presetNews: presetNews),
        scraper: scraper,
        enabled: enabled)
    return (dec, scraper)
}

// MARK: - Session status state machine

@Suite struct XueqiuSessionStatusTests {
    @Test func only_valid_and_expiring_may_scrape() {
        #expect(XueqiuSessionStatus.valid.canScrape)
        #expect(XueqiuSessionStatus.expiring.canScrape)
        #expect(!XueqiuSessionStatus.unknown.canScrape)
        #expect(!XueqiuSessionStatus.expired.canScrape)
        #expect(!XueqiuSessionStatus.needsLogin.canScrape)
    }

    @Test func round_trips_through_raw_value() {
        for s in [XueqiuSessionStatus.unknown, .valid, .expiring, .expired, .needsLogin] {
            #expect(XueqiuSessionStatus(rawValue: s.rawValue) == s)
        }
    }
}

// MARK: - Decorator gating + graceful degradation

@Suite struct BYODiscussionNewsDecoratorTests {

    @Test func valid_session_flows_lines_into_news_for_cn_ticker() async throws {
        let (dec, scraper) = makeDecorator(
            enabled: true, status: .valid,
            lines: ["看好后市", "估值合理"])
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.news == ["[雪球] 看好后市", "[雪球] 估值合理"])
        #expect(await scraper.wasCalled() == 1)
    }

    @Test func expiring_session_still_scrapes() async throws {
        let (dec, _) = makeDecorator(
            enabled: true, status: .expiring, lines: ["仍可抓取"])
        let s = try await dec.snapshot(symbol: "0700.HK", asOf: Date())
        #expect(s.news == ["[雪球] 仍可抓取"])
    }

    @Test func appends_after_existing_news_without_clobbering() async throws {
        let (dec, _) = makeDecorator(
            enabled: true, status: .valid,
            lines: ["来自雪球"], presetNews: ["已有新闻"])
        let s = try await dec.snapshot(symbol: "000001.SZ", asOf: Date())
        #expect(s.news == ["已有新闻", "[雪球] 来自雪球"])
    }

    @Test func expired_session_passes_through_and_never_scrapes() async throws {
        let (dec, scraper) = makeDecorator(
            enabled: true, status: .expired, lines: ["不应出现"])
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.news.isEmpty)
        #expect(await scraper.wasCalled() == 0)   // never even attempted
    }

    @Test func needs_login_passes_through() async throws {
        let (dec, scraper) = makeDecorator(
            enabled: true, status: .needsLogin, lines: ["x"])
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.news.isEmpty)
        #expect(await scraper.wasCalled() == 0)
    }

    @Test func empty_scrape_leaves_snapshot_unchanged() async throws {
        let (dec, scraper) = makeDecorator(
            enabled: true, status: .valid, lines: [], presetNews: ["保留"])
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.news == ["保留"])
        #expect(await scraper.wasCalled() == 1)   // tried, got nothing → no-op
    }

    @Test func non_cn_ticker_is_never_touched() async throws {
        let (dec, scraper) = makeDecorator(
            enabled: true, status: .valid, lines: ["should not appear"])
        let s = try await dec.snapshot(symbol: "NVDA", asOf: Date())
        #expect(s.news.isEmpty)
        #expect(await scraper.wasCalled() == 0)
    }

    @Test func flag_off_is_a_pure_passthrough_even_with_valid_session() async throws {
        let (dec, scraper) = makeDecorator(
            enabled: false, status: .valid,
            lines: ["should not appear"], presetNews: ["保留"])
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.news == ["保留"])
        #expect(await scraper.wasCalled() == 0)
    }

    @Test func caps_appended_lines_at_max() async throws {
        let many = (1...20).map { "post\($0)" }
        let scraper = MockScraper(status: .valid, lines: many)
        let dec = BYODiscussionNewsDecorator(
            base: StubBase(), scraper: scraper, enabled: true, maxLines: 3)
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.news.count == 3)
        #expect(s.news.first == "[雪球] post1")
    }
}
