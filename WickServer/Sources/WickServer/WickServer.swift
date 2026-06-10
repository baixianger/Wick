import Foundation
import Hummingbird
import TradingFloor

/// Entry point: read config, assemble the data chain + desk + queue, run.
@main
struct WickServer {
    static func main() async throws {
        let config = Configuration.fromEnvironment()

        // Shared, persistent report cache (swap DiskReportStore → Postgres in prod).
        let store = DiskReportStore(directory: config.storeDirectory)

        // Data chain (decorators): MarketRouter splits CN (EastMoney, no key
        // required) from US (FMP, BYO key) at the base. Then layered:
        // Finnhub news → FRED macro. The news / macro decorators only fill
        // missing slots, so they degrade gracefully for CN tickers (whose
        // localized news + macro will land via dedicated EastMoney
        // decorators in later phases).
        let us: any MarketDataProvider = config.fmpKey
            .map { FMPMarketDataProvider(apiKey: $0) } ?? StubMarketDataProvider()
        var data: any MarketDataProvider = config.enableChinaMarkets
            ? MarketRouter(cn: EastMoneyMarketDataProvider(), fallback: us)
            : us
        if config.enableChinaMarkets {
            // Financial-statements decorator. No-op for non-CN symbols.
            data = EastMoneyFinancialProvider(base: data)
            // CCASS northbound (北向) shareholding — appends the latest
            // QUARTER's foreign-ownership line to `fundamentals` for A-shares.
            // Source: HKEX CCASS Stock Connect full-list (plain GET, no key);
            // EastMoney's per-stock tables froze in mid-2024. Quarter-cache.
            data = CCASSNorthboundDecorator(base: data)
            // CN news + filings (资讯 + 公告) for CN/HK tickers; fills
            // `news` only when empty, so it stacks with Finnhub. No key.
            data = EastMoneyNewsProvider(base: data)
            // Main-force capital flow (资金流向) appended to technicals
            // for A-share tickers. No key.
            data = EastMoneyFundFlowDecorator(base: data)
            // 融资融券 (margin) appended to capitalFlow for A-shares. No key.
            data = EastMoneyMarginDecorator(base: data)
            // 龙虎榜 (dragon-tiger) appended to capitalFlow only when the
            // A-share triggered the list recently. No key.
            data = EastMoneyBillboardDecorator(base: data)
        }
        if let finnhub = config.finnhubKey {
            data = FinnhubNewsProvider(base: data, finnhub: FinnhubClient(apiKey: finnhub))
        }
        // CN macro decorator — no key, always on when CN markets are
        // enabled. Fills `macro` for CN/HK symbols; non-CN symbols pass
        // through so the FRED decorator below catches them.
        if config.enableChinaMarkets {
            data = EastMoneyMacroProvider(base: data)
        }
        if let fred = config.fredKey {
            data = FredMacroProvider(base: data, fred: FredClient(apiKey: fred))
        }
        // Broad-market index context — adds one line to `macro` showing
        // CSI 300 / HSI / SPX behaviour so the analyst sees regime
        // alongside the ticker. No key required.
        data = SectorContextDecorator(base: data)
        // Per-stock industry/theme boards with day moves (所属板块)
        // for CN/HK tickers. No key.
        data = BoardContextDecorator(base: data)
        // Cross-asset context — WTI / Gold / BTC / DXY / VIX in one
        // line. Useful as a "global climate" indicator the LLM can
        // cross-reference against the stock's micro-climate. No key.
        data = CrossAssetContextDecorator(base: data)
        // Overnight external markets — CN/HK tickers only: US indices,
        // Golden Dragon ADRs, FTSE A50, USD/CNH, US 10Y yield. The
        // pre-open checklist an A-share analyst reads first. No key.
        data = OvernightContextDecorator(base: data)

        // LLM: Anthropic → OpenRouter (cheap/free models) → offline canned.
        let llm: any LLMProvider
        var quickModel = "claude-haiku-4-5-20251001"
        var deepModel = "claude-opus-4-7"
        if let key = config.anthropicKey {
            llm = AnthropicProvider(apiKey: key)
        } else if let key = config.openRouterKey {
            let model = config.openRouterModel ?? "deepseek/deepseek-v4-flash:free"
            llm = OpenAICompatibleProvider(
                baseURL: URL(string: "https://openrouter.ai/api/v1")!, apiKey: key)
            quickModel = model; deepModel = model
            print("Using OpenRouter model: \(model)")
        } else {
            print("⚠️  OFFLINE MODE: no LLM key — canned analysis (not for production)")
            llm = OfflineLLM()
        }

        let desk = TradingFloor(llm: llm, data: data,
                                config: TradingFloorConfig(quickModel: quickModel,
                                                           deepModel: deepModel,
                                                           maxDebateRounds: 1))
        let queue = ReportQueue(desk: desk, store: store, maxWorkers: config.maxWorkers)
        // Pass `llm` + `deepModel` to the router so the
        // `/v1/chat/completions` route can broker chat traffic for
        // server-mode Wicker users (SaaS tier in [[wick-business-model]]).
        let router = buildRouter(queue: queue, llm: llm, defaultModel: deepModel)

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("0.0.0.0", port: config.port))
        )
        print("WickServer on :\(config.port) — \(config.maxWorkers) workers — store \(config.storeDirectory.path)")
        try await app.runService()
    }
}
