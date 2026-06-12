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

    /// GUI-side responder for the cross-process MCP bridge (TODO #39). Holds a
    /// `BridgeServer` that, WHEN the user opts in (`exposeWickerViaMCP`), polls
    /// the App-Group `Bridge/` dir and services third-party `wick.web_*` /
    /// `wick.*_discussion` MCP calls against the live `BrowserSessionManager`.
    /// `nil` below macOS 26 (no `WebPage` / `BrowserSessionManager`). Typed as
    /// `AnyObject?` so this file stays free of the macOS-26 availability floor
    /// at property level (same shape as `browserSession`).
    @ObservationIgnored let bridgeServer: AnyObject?

    init() {
        self.tools = ToolRegistry()
        let userSkillsDir = Self.userSkillsDirectory()
        self.skills = SkillRegistry(userDirectory: userSkillsDir)
        if #available(macOS 26.0, *) {
            let manager = BrowserSessionManager()
            self.browserSession = manager
            self.bridgeServer = BridgeServer(manager: manager)
        } else {
            self.browserSession = nil
            self.bridgeServer = nil
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
            ]
            // Always-on free EastMoney CN extras (资金流 / F10财务 / 龙虎榜 /
            // 涨停板) — a free replacement for tushare's points-gated data. No
            // key; the agent calls them when a CN ticker is in play. One shared
            // fetcher across the four tools.
            + EastMoneyExtrasTools.all()
            // Always-on free FINRA US 空头持仓 (short interest) — `us.short_interest`.
            // No key; the agent calls it when a US ticker is in play. Returns
            // a "仅美股" message for CN / HK / intl symbols.
            + ShortInterestTools.all()
            // Always-on free SEC EDGAR US tools (official, no-key, descriptive-UA):
            // `us.insider` (Form 4 内部人交易) + `us.financials` (XBRL 财务).
            // US-only; "未找到 SEC 备案" for CN / HK / intl symbols.
            + USEdgarTools.all()
            // Always-on free Yahoo quoteSummary analyst tool — `us.analyst`
            // (评级分布 / 目标价 / 推荐 / 下次财报日). Cookie+crumb flow; reports
            // 暂不可用 when Yahoo throttles or changes the flow.
            + USAnalystTools.all())
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
        reconfigureWebTools(with: settings)
    }

    /// Register or retract Wicker's `web.*` browser-operation tools based on the
    /// opt-in `enableWickerBrowser` flag. When ON (and we're on macOS 26 with a
    /// live `BrowserSessionManager`), the 7 `WebTools` are registered into the
    /// SAME `ToolRegistry` the model already dispatches through — each forwarding
    /// to the manager's `@MainActor` driver methods via a `@Sendable` closure
    /// bridge (`WebToolDriver`), so WebKit stays app-side and the macOS-26
    /// availability is confined to this site. When OFF, the tools are
    /// unregistered (idempotent — keyed by `spec.name`), so toggling the flag at
    /// runtime takes effect on the very next chat turn with no rebuild.
    ///
    /// Host calls this on launch + on every `enableWickerBrowser` change.
    func reconfigureWebTools(with settings: AgentSettings) {
        guard settings.enableWickerBrowser,
              #available(macOS 26.0, *),
              let manager = browserSession as? BrowserSessionManager
        else {
            Task { [tools] in await tools.unregisterAll(names: WebTools.names) }
            return
        }
        // One-switch write guardrail: when `allowWickerBrowserWrites` is off, the
        // three page-mutating tools (click / type / eval) are swapped for a
        // refusal that points the user to the toggle — read-only browsing, no
        // per-action prompts. Navigation / read / snapshot / fetchJSON / tab
        // management are never gated.
        let allowWrites = settings.allowWickerBrowserWrites
        let readOnlyRefusal = "只读模式：已在「设置 → 工作流 → BYO 浏览器」中关闭浏览器写操作。"
            + "如需让 Wicker 点击 / 输入 / 执行脚本，请在那里开启「允许写操作」。"

        // Build the main-actor bridge over the live manager. The closures hop to
        // `@MainActor` (the manager's isolation) on each call; the AgentTool
        // itself stays `Sendable` and never captures the non-Sendable manager.
        let driver = WebToolDriver(
            navigate:  { @Sendable url in await manager.navigate(to: url) },
            readText:  { @Sendable sel in await manager.readText(selector: sel) },
            snapshot:  { @Sendable full, viewportOnly, verbose in
                await manager.snapshotOutline(full: full, viewportOnly: viewportOnly, verbose: verbose) },
            click:     { @Sendable ref, sel in
                guard allowWrites else { return readOnlyRefusal }
                return await manager.click(ref: ref, selector: sel) },
            type:      { @Sendable ref, sel, txt, enter in
                guard allowWrites else { return readOnlyRefusal }
                return await manager.type(ref: ref, selector: sel, text: txt, enter: enter) },
            eval:      { @Sendable js in
                guard allowWrites else { return readOnlyRefusal }
                return await manager.eval(js: js) },
            fetchJSON: { @Sendable url in await manager.fetchJSON(url: url) },
            tabs:      { @Sendable in await manager.listTabsFormatted() },
            newTab:    { @Sendable url in await manager.newTab(url: url) },
            switchTab: { @Sendable ref in await manager.switchTab(ref: ref) },
            closeTab:  { @Sendable ref in await manager.closeTab(ref: ref) })
        let webTools = WebTools.all(driver: driver)
        Task { [tools] in await tools.registerAll(webTools) }
    }

    /// Start or stop the GUI-side MCP bridge server (TODO #39) per the opt-in
    /// `exposeWickerViaMCP` gate. When ON (and on macOS 26 with a live
    /// `BridgeServer`), the server polls the App-Group `Bridge/` dir and answers
    /// third-party `wick.web_*` / `wick.*_discussion` MCP calls against the live
    /// browser/社交 sessions. When OFF, the server stops and NO bridge requests
    /// are serviced. Host calls this on launch + on every `exposeWickerViaMCP` /
    /// `enableWickerBrowser` change.
    func reconfigureBridge(with settings: AgentSettings) {
        guard #available(macOS 26.0, *),
              let server = bridgeServer as? BridgeServer
        else { return }
        server.reconfigure(with: settings)
    }

    /// Wire the agent's `portfolio.*` tools over the app's live `HoldingsStore`
    /// so Wicker can read and write the user's 持仓. `HoldingsStore` is created
    /// in `ContentView` (window-scoped, `@MainActor @Observable`), not here, so
    /// the host calls this from `ContentView.onAppear` once the store exists.
    ///
    /// We capture the store in `@Sendable` closures that hop to `@MainActor`
    /// (the store's isolation) — same bridge shape as `reconfigureWebTools`, so
    /// the `AgentTool`s stay `Sendable` and never hold the non-Sendable store
    /// directly. Idempotent: re-registering by `spec.name` overwrites.
    func attachPortfolio(_ store: HoldingsStore) {
        let driver = PortfolioToolDriver(
            add: { @Sendable req in
                await MainActor.run {
                    store.add(Holding(
                        symbol: req.symbol,
                        name: req.name,
                        side: req.side,
                        date: req.date,
                        quantity: req.quantity,
                        price: req.price,
                        currency: req.currency,
                        source: .manual))
                    // The store canonicalises the symbol on the way in (e.g.
                    // `BE:XNYS` → `BE`); report the CANONICAL form so the agent's
                    // confirmation matches what was actually stored + charted.
                    let stored = HoldingsStore.canonicalSymbol(req.symbol)
                    let note = stored == req.symbol ? "" : " (from \(req.symbol))"
                    let verb = req.side == .buy ? "Bought" : "Sold"
                    return "✅ \(verb) \(Self.trimNumber(req.quantity)) \(stored)\(note) @ "
                        + "\(Self.trimNumber(req.price)) \(req.currency) "
                        + "(\(Self.dayString(req.date))). Added to portfolio."
                }
            },
            list: { @Sendable in
                await MainActor.run {
                    let positions = store.positions()
                    guard !positions.isEmpty else {
                        return "Portfolio is empty — no positions yet."
                    }
                    let lines = positions.map { p in
                        "- \(p.symbol) (\(p.name)): net \(Self.trimNumber(p.netQuantity)) "
                            + "@ avg \(Self.trimNumber(p.averageBuyPrice)) \(p.currency) "
                            + "[\(p.transactionCount) tx]"
                    }
                    return "Current positions (\(positions.count)):\n" + lines.joined(separator: "\n")
                }
            },
            transactions: { @Sendable symbol in
                await MainActor.run {
                    let rows = symbol.map { store.transactions(for: $0) }
                        ?? store.holdings.sorted { $0.date < $1.date }
                    guard !rows.isEmpty else {
                        return symbol.map { "No transactions for \($0)." }
                            ?? "Portfolio is empty — no transactions yet."
                    }
                    let lines = rows.map { h in
                        "- id=\(h.id.uuidString) | \(h.symbol) \(h.side.rawValue) "
                            + "\(Self.trimNumber(h.quantity)) @ \(Self.trimNumber(h.price)) "
                            + "\(h.currency) (\(Self.dayString(h.date)))"
                    }
                    let scope = symbol.map { " for \($0)" } ?? ""
                    return "Transactions\(scope) (\(rows.count)):\n" + lines.joined(separator: "\n")
                }
            },
            remove: { @Sendable idString in
                await MainActor.run {
                    guard let uuid = UUID(uuidString: idString) else {
                        return "Error: \"\(idString)\" is not a valid transaction id. "
                            + "Call portfolio.transactions to get ids."
                    }
                    guard let h = store.holdings.first(where: { $0.id == uuid }) else {
                        return "No transaction with id \(idString) — it may already be gone. "
                            + "Call portfolio.transactions for the current ledger."
                    }
                    store.remove(id: uuid)
                    return "🗑️ Removed: \(h.symbol) \(h.side.rawValue) \(Self.trimNumber(h.quantity)) @ "
                        + "\(Self.trimNumber(h.price)) \(h.currency) (\(Self.dayString(h.date)))."
                }
            })
        Task { [tools] in await tools.registerAll(PortfolioTools.all(driver: driver)) }
    }

    /// Format a double without a trailing `.0` for whole numbers, else 2 dp.
    nonisolated private static func trimNumber(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.2f", v)
    }
    nonisolated private static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
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
