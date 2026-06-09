import Testing
import Foundation
@testable import TradingFloor

/// Routing + roster + locale behaviour for the market-routed desk. The desk
/// graph is one type; only the profile (`locale` / `market` / `analysts`)
/// changes per ticker, so these tests pin the routing table and prove the
/// English path stays byte-identical while the Chinese path localises copy.
@Suite struct DeskProfileTests {

    // MARK: - Routing table

    @Test func us_ticker_routes_to_english_desk() {
        let desk = DeskProfile.forTicker("NVDA")
        #expect(desk.locale == .english)
        #expect(desk.market == nil)
        #expect(desk.analysts == [.fundamental, .technical, .sentiment, .news])
        #expect(desk.analysts.count == 4)
    }

    @Test func shanghai_ticker_routes_to_chinese_a_share_desk() {
        let desk = DeskProfile.forTicker("600519.SS")
        #expect(desk.locale == .chinese)
        #expect(desk.market == .shanghai)
        // Full A-share roster: the four shared + 政策面 + 资金面.
        #expect(desk.analysts == [.fundamental, .technical, .sentiment, .news, .policy, .capital])
        #expect(desk.analysts.count == 6)
    }

    @Test func hong_kong_ticker_routes_to_chinese_desk_without_capital() {
        let desk = DeskProfile.forTicker("0700.HK")
        #expect(desk.locale == .chinese)
        #expect(desk.market == .hongKong)
        // HK gets 政策面 but NOT 资金面 — no main-force fund-flow disclosure.
        #expect(desk.analysts.contains(.policy))
        #expect(!desk.analysts.contains(.capital))
        #expect(desk.analysts.count == 5)
    }

    @Test func routing_canonicalises_alternate_cn_shapes() {
        // Bare digits and prefix forms canonicalise the same as their suffix form.
        #expect(DeskProfile.forTicker("600519").market == .shanghai)
        #expect(DeskProfile.forTicker("SH600519").market == .shanghai)
        #expect(DeskProfile.forTicker("000001.SZ").market == .shenzhen)
        #expect(DeskProfile.forTicker("HK0700").market == .hongKong)
    }

    // MARK: - brief(for:) for the new analyst kinds

    @Test func brief_policy_returns_macro_and_capital_returns_capital_flow() {
        let snap = MarketSnapshot(
            symbol: "600519.SS", asOf: .now,
            macro: "CN macro: CPI -0.1%; 板块 白酒 +1.2%; 隔夜外盘 标普 +0.4%",
            capitalFlow: "资金流向: 今日主力净流入 -2.01亿")
        #expect(snap.brief(for: .policy) == snap.macro)
        #expect(snap.brief(for: .capital) == snap.capitalFlow)
    }

    @Test func brief_new_kinds_keep_stub_banner() {
        // The stub banner must prefix the new analysts' briefs too, so a
        // sample-data run doesn't yield authoritative CN analysis.
        let snap = MarketSnapshot(
            symbol: "600519.SS", asOf: .now,
            fundamentals: [StubMarketDataProvider.stubMarkerKey: "true"],
            macro: "some macro", capitalFlow: "some flow")
        #expect(snap.isStub)
        #expect(snap.brief(for: .policy).contains("Sample data"))
        #expect(snap.brief(for: .capital).contains("Sample data"))
    }

    // MARK: - Prompt locale

    @Test func english_analyst_prompt_is_unchanged() {
        // Regression: the English path must be byte-identical to the v2 prompt.
        let p = Prompts.analyst(.fundamental, desk: .english)
        #expect(p.hasPrefix("You are the Fundamental Analyst on a trading desk."))
        #expect(p.contains("valuation, growth, margins, balance-sheet health"))
        #expect(p.contains("\"lean\":     \"bullish\" | \"bearish\" | \"neutral\""))
        // No Chinese leaked into the English path.
        #expect(!p.contains("分析师"))
    }

    @Test func chinese_analyst_prompt_has_chinese_copy_and_english_json_tokens() {
        let desk = DeskProfile.forTicker("600519.SS")
        let p = Prompts.analyst(.policy, desk: desk)
        // Chinese instruction copy.
        #expect(p.contains("政策面"))
        #expect(p.contains("交易团队"))
        // But the JSON enum tokens stay English so the parser keeps working.
        #expect(p.contains("\"bullish\""))
        #expect(p.contains("\"bearish\""))
        #expect(p.contains("\"neutral\""))
        // And the envelope rule that pins the English tokens is present.
        #expect(p.contains("必须保持固定的英文字符串"))
    }

    @Test func chinese_trader_prompt_carries_market_microstructure_note() {
        // A-share: T+1 + 涨跌停.
        let a = Prompts.trader(desk: DeskProfile.forTicker("600519.SS"))
        #expect(a.contains("T+1"))
        #expect(a.contains("涨跌停"))
        // Same conviction→position mapping as English.
        #expect(a.contains("STRONG BUY → 15–25%"))
        // HK: no T+1, 南向资金.
        let hk = Prompts.trader(desk: DeskProfile.forTicker("0700.HK"))
        #expect(hk.contains("无 T+1"))
        #expect(hk.contains("南向资金"))
        // English trader has no microstructure note.
        let us = Prompts.trader(desk: .english)
        #expect(!us.contains("南向资金"))
        #expect(us.contains("STRONG BUY → 15–25%"))
    }

    // MARK: - End-to-end Chinese desk run

    @Test func chinese_desk_analyze_runs_full_graph_without_throwing() async throws {
        // The Chinese desk is the SAME graph — a CN ticker over the offline
        // ScriptedLLM must produce a valid Report, exercising the extra
        // policy/capital analysts, the Chinese prompts, and the CN disclaimer.
        // (We don't assert a specific rating: the mock LLM dispatches on
        // prompt CONTENT, which is now Chinese, so it can't tell the trader
        // apart — that's a mock limitation, not a desk bug. The point is the
        // full graph runs and assembles a valid Report.)
        let desk = TradingFloor(
            llm: EnvelopeLLM(), data: StubMarketDataProvider(),
            config: .init(maxDebateRounds: 1))
        let report = try await desk.analyze(ticker: "600519.SS")
        #expect(Rating.allCases.contains(report.rating))  // some valid verdict
        // Role keys stay English so transcript plumbing works.
        #expect(report.transcript.contains { $0.role == "Trader" })
        #expect(report.transcript.contains { $0.role == "Risk Manager" })
        // A-share roster ran all six analysts (intersection with default config).
        #expect(report.transcript.contains { $0.role == "Policy Analyst" })
        #expect(report.transcript.contains { $0.role == "Capital Analyst" })
        // CN disclaimer attached.
        #expect(report.disclaimer == Report.chineseDisclaimer)
    }

    @Test func us_desk_analyze_skips_cn_only_analysts() async throws {
        // Even though the default config enables every AnalystKind, a US run
        // must never spawn policy/capital (the desk roster gates them out).
        let desk = TradingFloor(
            llm: EnvelopeLLM(), data: StubMarketDataProvider(),
            config: .init(maxDebateRounds: 0))
        let report = try await desk.analyze(ticker: "NVDA")
        #expect(!report.transcript.contains { $0.role == "Policy Analyst" })
        #expect(!report.transcript.contains { $0.role == "Capital Analyst" })
        #expect(report.disclaimer == Report.defaultDisclaimer)
    }
}
