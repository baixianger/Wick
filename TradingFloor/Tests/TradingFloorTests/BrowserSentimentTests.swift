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
        // Lines arrive already formatted + self-tagged from the live scraper; the
        // decorator appends them verbatim (no re-wrapping).
        let (dec, scraper) = makeDecorator(
            enabled: true, status: .valid,
            lines: ["[雪球·张三] 看好后市 (赞12 评3)", "[雪球·李四] 估值合理 (赞5 评1)"])
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.news == ["[雪球·张三] 看好后市 (赞12 评3)", "[雪球·李四] 估值合理 (赞5 评1)"])
        #expect(await scraper.wasCalled() == 1)
    }

    @Test func expiring_session_still_scrapes() async throws {
        let (dec, _) = makeDecorator(
            enabled: true, status: .expiring, lines: ["[雪球·甲] 仍可抓取 (赞0 评0)"])
        let s = try await dec.snapshot(symbol: "0700.HK", asOf: Date())
        #expect(s.news == ["[雪球·甲] 仍可抓取 (赞0 评0)"])
    }

    @Test func appends_after_existing_news_without_clobbering() async throws {
        let (dec, _) = makeDecorator(
            enabled: true, status: .valid,
            lines: ["[雪球·王五] 来自雪球 (赞0 评0)"], presetNews: ["已有新闻"])
        let s = try await dec.snapshot(symbol: "000001.SZ", asOf: Date())
        #expect(s.news == ["已有新闻", "[雪球·王五] 来自雪球 (赞0 评0)"])
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
        let many = (1...20).map { "[雪球·u\($0)] post\($0) (赞0 评0)" }
        let scraper = MockScraper(status: .valid, lines: many)
        let dec = BYODiscussionNewsDecorator(
            base: StubBase(), scraper: scraper, enabled: true, maxLines: 3)
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.news.count == 3)
        #expect(s.news.first == "[雪球·u1] post1 (赞0 评0)")
    }
}

// MARK: - Pure JSON parser + line formatter (no WebKit)

@Suite struct XueqiuPostParserTests {

    /// Representative `/statuses/search.json` response shape (snowball-cli
    /// `searchPosts` / `formatPost`): a top-level `list` of posts, each with a
    /// `description` (HTML body), `user.screen_name`, and reply/like counts.
    private let sampleJSON = """
    {
      "count": 2,
      "list": [
        {
          "description": "<a href=\\"/S/SH600519\\">$贵州茅台$</a> 看好<b>后市</b>，&amp; 估值合理。",
          "user": { "screen_name": "张三" },
          "reply_count": 3,
          "like_count": 12,
          "retweet_count": 1
        },
        {
          "text": "短线观望，等回调",
          "user": { "screen_name": "李四" },
          "reply_count": 0,
          "fav_count": 7
        }
      ]
    }
    """

    @Test func parses_search_json_into_posts() {
        let posts = XueqiuPostParser.parse(jsonString: sampleJSON)
        #expect(posts.count == 2)
        // HTML stripped, entity decoded, whitespace collapsed.
        #expect(posts[0].author == "张三")
        // Tags → space (safe against `<br>`/block tags running words together),
        // then whitespace collapsed; `&amp;` decoded.
        #expect(posts[0].text == "$贵州茅台$ 看好 后市 ，& 估值合理。")
        #expect(posts[0].likeCount == 12)
        #expect(posts[0].replyCount == 3)
        // `text` fallback + `fav_count` → likes fallback.
        #expect(posts[1].author == "李四")
        #expect(posts[1].text == "短线观望，等回调")
        #expect(posts[1].likeCount == 7)
        #expect(posts[1].replyCount == 0)
    }

    @Test func formats_post_into_news_line() {
        let post = XueqiuPost(author: "张三", text: "看好后市，估值合理。",
                              likeCount: 12, replyCount: 3)
        #expect(post.newsLine() == "[雪球·张三] 看好后市，估值合理。 (赞12 评3)")
    }

    @Test func authorless_post_drops_the_author_segment() {
        let post = XueqiuPost(author: "", text: "匿名观点",
                              likeCount: 0, replyCount: 0)
        #expect(post.newsLine() == "[雪球] 匿名观点 (赞0 评0)")
    }

    @Test func long_body_is_truncated_with_ellipsis() {
        let body = String(repeating: "市", count: 100)
        let post = XueqiuPost(author: "甲", text: body, likeCount: 1, replyCount: 2)
        let line = post.newsLine(textCap: 10)
        #expect(line == "[雪球·甲] " + String(repeating: "市", count: 10) + "… (赞1 评2)")
    }

    @Test func error_code_response_yields_no_posts() {
        let json = #"{ "error_code": 400016, "error_description": "登录失效" }"#
        #expect(XueqiuPostParser.parse(jsonString: json).isEmpty)
    }

    @Test func non_json_yields_no_posts() {
        #expect(XueqiuPostParser.parse(jsonString: "<html>login wall</html>").isEmpty)
    }

    @Test func tolerates_data_dot_list_wrapping() {
        let json = #"{ "data": { "list": [ { "text": "x", "user": { "screen_name": "甲" } } ] } }"#
        let posts = XueqiuPostParser.parse(jsonString: json)
        #expect(posts.count == 1)
        #expect(posts[0].author == "甲")
    }

    @Test func parses_created_at_millis_and_permalink() {
        // 雪球 search posts carry `created_at` (epoch ms) + a relative `target`.
        let json = #"{ "list": [ { "text": "结构化", "user": { "screen_name": "甲" }, "created_at": 1700000000000, "target": "/1234/5678" } ] }"#
        let posts = XueqiuPostParser.parse(jsonString: json)
        #expect(posts.count == 1)
        #expect(posts[0].createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(posts[0].url?.absoluteString == "https://xueqiu.com/1234/5678")
    }

    @Test func missing_time_and_url_are_nil_not_a_failure() {
        let posts = XueqiuPostParser.parse(jsonString: sampleJSON)
        #expect(posts[0].createdAt == nil)
        #expect(posts[0].url == nil)
    }

    @Test func skips_empty_text_posts_but_keeps_others() {
        let json = #"{ "list": [ { "description": "<img src=\"x\">", "user": { "screen_name": "甲" } }, { "text": "有内容", "user": { "screen_name": "乙" } } ] }"#
        let posts = XueqiuPostParser.parse(jsonString: json)
        #expect(posts.count == 1)
        #expect(posts[0].text == "有内容")
    }
}

// MARK: - Symbol mapping (canonical → 雪球)

@Suite struct XueqiuSymbolMappingTests {
    @Test func maps_shanghai_to_sh_prefix() {
        #expect(CNSymbol.xueqiuSymbol("600519.SS") == "SH600519")
    }
    @Test func maps_shenzhen_to_sz_prefix() {
        #expect(CNSymbol.xueqiuSymbol("000001.SZ") == "SZ000001")
    }
    @Test func maps_hk_to_five_digit_form() {
        #expect(CNSymbol.xueqiuSymbol("0700.HK") == "00700")
    }
    @Test func non_cn_symbol_is_nil() {
        #expect(CNSymbol.xueqiuSymbol("NVDA") == nil)
        #expect(CNSymbol.xueqiuSymbol("AAPL.US") == nil)
    }
}
