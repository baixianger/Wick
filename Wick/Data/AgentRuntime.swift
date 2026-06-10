import Foundation
import Observation
import TradingFloor

/// Process-wide registry of `AgentTool`s + `Skill`s that the chat agent
/// (Wicker) and the workflow agent (`TradingFloor.analyze`) both
/// consult. Hosted at app level and injected via the environment so
/// any view that wants to instantiate a `ChatAgent` can read the
/// shared registries off `Environment(AgentRuntime.self)` without
/// rebuilding them per turn.
///
/// Market data provider is constructed from `AgentSettings` (BYO data
/// keys) — mirrors the exact decorator chain `WickServer.main`
/// assembles for the server tier, so BYO and server-mode users get
/// the same data shape into the agents:
///
///   FMPMarketDataProvider (or Yahoo fallback if no FMP key)
///     └─ FinnhubNewsProvider decorator   (if Finnhub key set)
///         └─ FredMacroProvider decorator (if FRED key set)
///             └─ wrapped in CachingMarketDataProvider (15-min TTL)
///
/// Tools are re-registered with the current provider whenever
/// `reconfigure(with:)` fires — host calls that on launch + on every
/// data-key change in Settings.
@MainActor
@Observable
final class AgentRuntime {

    let tools: ToolRegistry
    let skills: SkillRegistry

    /// App-scoped BYO-cookie browser session owner (雪球 Mode 1/2). Held here so
    /// its lifecycle is view-independent and the off-by-default 雪球 decorator
    /// can pull discussion lines from the same instance the UI logs in through.
    /// `nil` below macOS 26 (the `WebPage` API floor) — wiring then no-ops.
    @ObservationIgnored let browserSession: AnyObject?

    init() {
        self.tools = ToolRegistry()
        let userSkillsDir = Self.userSkillsDirectory()
        self.skills = SkillRegistry(userDirectory: userSkillsDir)
        if #available(macOS 26.0, *) {
            self.browserSession = BrowserSessionManager()
        } else {
            self.browserSession = nil
        }

        // Initial registration with the Yahoo-only baseline. The host
        // calls `reconfigure(with:)` once `AgentSettings` is available
        // to replace this with the full BYO chain.
        let baseline: any MarketDataProvider =
            CachingMarketDataProvider(wrapping: WickMarketDataProvider(), ttl: 900)
        Task { [tools, skills] in
            await tools.registerAll([
                MarketDataTool(data: baseline),
                SocialSentimentTool(
                    providers: [StubSocialSentimentProvider()],
                    interactive: true),
            ])
            await skills.reload()
        }
    }

    /// Rebuild the market data chain from the user's current data keys
    /// and re-register the tools. ToolRegistry's `register(_:)` is
    /// keyed by `tool.spec.name`, so re-registering with the same
    /// name overwrites the previous tool — no leak, no duplicate.
    func reconfigure(with settings: AgentSettings) {
        let provider = buildMarketData(from: settings)
        Task { [tools] in
            await tools.register(MarketDataTool(data: provider))
        }
    }

    /// Instance wrapper around the static chain builder that splices in the
    /// off-by-default 雪球 decorator when running on macOS 26 with the app-scoped
    /// `BrowserSessionManager` available. Kept separate from the `static`
    /// builder so the latter stays Foundation-only + reusable (and matches the
    /// server tier's pure assembly).
    func buildMarketData(from settings: AgentSettings) -> any MarketDataProvider {
        if #available(macOS 26.0, *),
           let manager = browserSession as? BrowserSessionManager
        {
            return Self.buildMarketData(
                from: settings,
                xueqiuScraper: manager,
                xueqiuEnabled: settings.enableXueqiuSentiment)
        }
        return Self.buildMarketData(from: settings)
    }

    /// Build the full EastMoney(CN) → FMP(US) / Yahoo(intl) → Finnhub → FRED
    /// chain that mirrors `WickServer.main`. Each decorator is opt-in:
    /// missing keys degrade gracefully (Yahoo fallback for base, empty news /
    /// macro for the decorators). Caching wrapper sits at the outermost
    /// layer.
    static func buildMarketData(
        from settings: AgentSettings,
        xueqiuScraper: (any XueqiuScraping)? = nil,
        xueqiuEnabled: Bool = false
    ) -> any MarketDataProvider {
        // Base layer: split first by Chinese-market suffix (`.SS` / `.SZ` /
        // `.HK`) → EastMoney's open endpoints. Everything else falls through
        // to the US / international split that depends on whether the user
        // configured an FMP key.
        let nonCN: any MarketDataProvider
        if settings.fmpKey.isEmpty {
            nonCN = WickMarketDataProvider()
        } else {
            nonCN = InternationalRouter(
                us: FMPMarketDataProvider(apiKey: settings.fmpKey),
                intl: WickMarketDataProvider())
        }
        var data: any MarketDataProvider = MarketRouter(
            cn: EastMoneyMarketDataProvider(),
            fallback: nonCN
        )
        // Financial-statements decorator. No-op for non-CN symbols; for CN
        // tickers it merges the latest quarter's income-statement digest
        // into `fundamentals` (营收 YoY, ROE, 毛利率, EPS, 经营现金流, …).
        data = EastMoneyFinancialProvider(base: data)
        // CCASS northbound (北向) shareholding — appends the latest QUARTER's
        // foreign-ownership line to `fundamentals` for A-shares (持股 % of
        // float + share count + a 2026Qn label). Source: HKEX CCASS Stock
        // Connect full-list (plain GET, no key); EastMoney's per-stock tables
        // froze in mid-2024. Quarter-cache: one fetch per market serves all.
        data = CCASSNorthboundDecorator(base: data)
        // CN news + filings decorator — fills `news` for CN/HK tickers from
        // EastMoney 资讯 + 公告. No key. Disjoint with Finnhub below (each
        // only fills an empty `news`), so order doesn't matter.
        data = EastMoneyNewsProvider(base: data)
        // BYO-cookie 雪球 discussion decorator — OFF BY DEFAULT. Appends 雪球
        // hot-post lines into `news` for CN/HK tickers ONLY when (a) the user
        // opted in (`enableXueqiuSentiment`) AND (b) a scraper is injected AND
        // (c) the session is valid. Best-effort: any failure / empty / expired
        // / non-CN ticker → pass-through, so it can never break the chain. Sits
        // right after the EastMoney news layer so the sentiment/news analysts
        // see the lines, and inside the cache below so scrapes are amortised.
        if let scraper = xueqiuScraper {
            data = BYODiscussionNewsDecorator(
                base: data, scraper: scraper, enabled: xueqiuEnabled)
        }
        // Main-force capital flow — appends 资金流向 to technicals for
        // A-share tickers. No key.
        data = EastMoneyFundFlowDecorator(base: data)
        // 融资融券 (margin) — appends 融资余额/融券余额 to capitalFlow for
        // A-share tickers. No key.
        data = EastMoneyMarginDecorator(base: data)
        // 龙虎榜 (dragon-tiger) — appends a 龙虎榜 line to capitalFlow ONLY
        // when the A-share triggered the list recently; otherwise nothing.
        // No key.
        data = EastMoneyBillboardDecorator(base: data)
        // Finnhub news decorator.
        if !settings.finnhubKey.isEmpty {
            data = FinnhubNewsProvider(
                base: data,
                finnhub: FinnhubClient(apiKey: settings.finnhubKey))
        }
        // CN macro decorator — no key, fills macro for CN/HK symbols only.
        data = EastMoneyMacroProvider(base: data)
        // FRED macro decorator — fills macro for non-CN symbols only
        // (guarded inside the provider). Adding both is safe.
        if !settings.fredKey.isEmpty {
            data = FredMacroProvider(
                base: data,
                fred: FredClient(apiKey: settings.fredKey))
        }
        // Broad-market index context — one line in macro per ticker
        // (CSI 300 / HSI / SPX), no key, sandbox-friendly.
        data = SectorContextDecorator(base: data)
        // Per-stock industry/theme boards with day moves (所属板块) for
        // CN/HK tickers. No key.
        data = BoardContextDecorator(base: data)
        // Cross-asset (global climate): WTI / Gold / BTC / DXY / VIX.
        // Yahoo Finance free chart endpoint, no key, Foundation HTTP.
        data = CrossAssetContextDecorator(base: data)
        // Overnight external markets — CN/HK tickers only: US indices,
        // Golden Dragon ADRs, FTSE A50, USD/CNH, US 10Y yield. Same
        // Yahoo endpoint, no key.
        data = OvernightContextDecorator(base: data)
        // Outermost: caching wrapper. 15-min TTL matches DeskRunner.
        return CachingMarketDataProvider(wrapping: data, ttl: 900)
    }

    /// Build a fresh `ChatAgent` for one user turn. Re-built per call
    /// so an `AgentSettings` change between turns (provider switch,
    /// model swap) takes effect immediately. The conversation lives
    /// in `ChatStore`, not on the agent.
    func makeChatAgent(llm: any LLMProvider,
                       config: TradingFloorConfig) -> ChatAgent
    {
        ChatAgent(llm: llm,
                  tools: tools,
                  skills: skills,
                  config: config)
    }

    private static func userSkillsDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true)
        else { return nil }
        let dir = base
            .appendingPathComponent("Wick", isDirectory: true)
            .appendingPathComponent("Skills", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - International router

/// Dispatches per-snapshot between a US provider (FMP) and an
/// international one (Yahoo via `WickMarketDataProvider`). FMP only
/// covers US-listed equities, so a HK / Shanghai / Tokyo / LSE
/// ticker fetched via FMP comes back empty — feeding the agent an
/// empty snapshot produces fabricated reports. Anything with a
/// recognized Yahoo exchange suffix goes straight to the intl
/// provider; everything else (plain symbols and `BRK.B`-style class
/// shares) goes to FMP.
struct InternationalRouter: MarketDataProvider {
    let us: any MarketDataProvider
    let intl: any MarketDataProvider

    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        if hasExchangeSuffix(symbol) {
            return try await intl.snapshot(symbol: symbol, asOf: asOf)
        }
        return try await us.snapshot(symbol: symbol, asOf: asOf)
    }

    private func hasExchangeSuffix(_ id: String) -> Bool {
        guard let dotIdx = id.lastIndex(of: ".") else { return false }
        let suffix = String(id[id.index(after: dotIdx)...]).uppercased()
        return YahooSymbol.exchangeSuffixes.contains(suffix)
    }
}
