import SwiftUI
import CoreCharts
import DataAdapters

/// Two-column shell. Search lives inside the sidebar; the detail-tab
/// picker (Overview / Chart / News / AI) lives in the window's top-right
/// toolbar so it stays visible no matter how the user scrolls.
struct ContentView: View {
    @State private var route: SidebarRoute? = .ticker(Ticker.samples[0].id)
    @State private var searchQuery: String = ""
    @State private var tab: DetailTab = .overview
    /// Global indicator config — owned by `WickApp` and injected via
    /// the environment so both ContentView (per-ticker chart) and
    /// Settings (Indicators tab) read/write the same instance.
    @Environment(ChartIndicatorConfig.self) private var indicatorConfig
    /// BYO agent + display knobs. Owns appearance + chart layout (formerly
    /// @State here) so the single Settings pane can drive them.
    @Environment(AgentSettings.self) private var agentSettings
    /// Tickers the user added via global search. Combined with
    /// `Ticker.samples` at render time. Persists across app restarts
    /// — only the (symbol, name) identity is stored; `series` is
    /// always rehydrated empty and refilled by `LiveDataStore` on
    /// first fetch.
    @State private var customTickers: [Ticker] = ContentView.loadCustomTickers()
    /// User-entered buy / sell transactions. Persists to UserDefaults.
    @State private var holdings = HoldingsStore()
    /// User-defined watchlist groups + selection. Persists to UserDefaults.
    @State private var watchlist = WatchlistStore()
    /// Global chat sessions for the Assistant route. Persists to disk
    /// (JSON in Application Support). Held here so opening / closing
    /// the route preserves state across the window's lifetime.
    @State private var chat = ChatStore()
    /// Latest debounced result set from `YahooSearchAdapter`.
    @State private var searchResults: [YahooSearchResult] = []
    /// One process-wide search adapter — Actor, so no `@State` ceremony.
    private let searchAdapter = YahooSearchAdapter()
    /// Validate-on-failure resolver: when a held symbol's live fetch fails, it
    /// searches the real provider for the authoritative ticker and rewrites the
    /// holding (covers broker formats the mechanical MIC table can't map).
    @State private var holdingResolver = HoldingSymbolResolver()
    @Environment(LiveDataStore.self) private var store
    /// Shared agent runtime (created in `WickApp`). Read here so the
    /// window-scoped `HoldingsStore` can be wired into Wicker's
    /// `portfolio.*` tools on appear — the store lives here, the runtime
    /// at app level, so this is the seam where they meet.
    @Environment(AgentRuntime.self) private var agentRuntime

    var body: some View {
        @Bindable var agentSettings = agentSettings
        let allTickers = Ticker.samples + customTickers
        let scoped = watchlist.filter(tickers: allTickers, holdings: holdings.holdings)
        let filtered = filteredTickers(scoped)
        // Symbols whose net position is flat (fully closed / 平仓) — surfaced so
        // the Holdings sidebar rows can carry a dimmed "已平仓" marker.
        let closedHoldingSymbols = ContentView.closedSymbols(in: holdings.holdings)
        let remote = remoteSearchResults(against: allTickers)
        let selectedTickerId: String? = {
            if case .ticker(let id) = route { return id }
            return nil
        }()
        // Detail lookup must include HELD surrogate tickers (symbols held but not
        // in the sample/custom universe), or tapping one in the Holdings list
        // fails the `allTickers` lookup and silently falls back to allTickers[0]
        // (Apple) — e.g. tapping BE or 07666 opened Apple's page.
        let lookupUniverse = allTickers
            + ContentView.heldSurrogateTickers(allTickers: allTickers,
                                                holdings: holdings.holdings)
        let selectedTicker = selectedTickerId
            .flatMap { id in lookupUniverse.first { $0.id == id } }
            ?? allTickers[0]

        NavigationSplitView {
            SidebarView(tickers: filtered,
                        route: $route,
                        searchQuery: $searchQuery,
                        searchResults: remote,
                        onPickResult: pickRemoteResult,
                        watchlist: watchlist,
                        holdingsCount: Set(holdings.holdings.map(\.symbol)).count,
                        closedHoldingSymbols: closedHoldingSymbols)
                .navigationTitle("Stocks")
                // Default the sidebar above the 240pt sparkline
                // threshold (SidebarView.sparklineMinWidth) so the
                // per-ticker mini chart is visible on first launch.
                // Min still allows narrowing for users who want it.
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 360)
        } detail: {
            // Detail content varies per route. The floating Wicker
            // composer overlays on every route except `.wicker`
            // itself (the workspace has its own in-place composer).
            // It's anchored bottom-trailing inside the detail pane,
            // so it doesn't get clipped by the sidebar.
            //
            // `.ignoresSafeArea(.container, edges: .top)` lets the
            // detail content extend all the way up under the
            // collapsed title bar zone — traffic lights then overlay
            // the content (Music / Mail style). Without this, SwiftUI
            // keeps a ~28pt safe-area inset for the (now-hidden)
            // title bar even when `.hiddenTitleBar` is set, leaving
            // an empty strip between traffic lights and the first
            // visible content row. Each per-route view adds its own
            // top padding so the page title doesn't crash into the
            // top of the window edge.
            Group {
                switch route {
                case .portfolio:
                    PortfolioView(store: holdings)
                case .wicker:
                    WickerView(store: chat)
                        .environment(holdings)
                case .market:
                    MarketView(universe: allTickers,
                               indicators: indicatorConfig)
                case .ticker, .none:
                    DetailView(ticker: selectedTicker,
                               tab: $tab,
                               splitView: $agentSettings.chartSplitView,
                               indicators: indicatorConfig,
                               holdings: holdings)
                        .id(selectedTicker.id)
                }
            }
            // Respect the top safe area on EVERY route so the toolbar (and the
            // window tab bar below it) keep their height and content stacks
            // underneath — no overlap, and no top-content clipping in fullscreen.
            // (Was `.ignoresSafeArea(.container, edges: .top)`, which clawed back
            // space under the old hidden title bar but let the tab bar / notch
            // overlap the content.)
            .overlay(alignment: .bottomTrailing) {
                if shouldShowFloatingComposer {
                    FloatingWickerComposer(
                        chat: chat,
                        route: $route,
                        contextSymbol: selectedTickerIDForRoute
                    )
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .task(id: searchQuery) {
            try? await Task.sleep(nanoseconds: 280_000_000)
            if Task.isCancelled { return }
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard q.count >= 1 else {
                searchResults = []
                return
            }
            do {
                let r = try await searchAdapter.search(query: q)
                if !Task.isCancelled { searchResults = r }
            } catch {
                if !Task.isCancelled { searchResults = [] }
            }
        }
        // Window toolbar deliberately empty — both the tab picker AND
        // the indicators button live inside `DetailView.header` now,
        // so with `.hiddenTitleBar` the chrome above the content
        // collapses entirely (traffic lights overlay the content
        // edge directly, no toolbar strip). This claws back the last
        // ~38pt of vertical space.
        .onAppear {
            // Warm the cache with daily series for every watchlist ticker
            // so the sparklines + header prices switch to live within a
            // few hundred ms of app launch.
            for t in allTickers {
                _ = store.series(for: t.symbol,
                                 interval: .d1,
                                 fallback: t.dailySeries)
            }
            // ALSO warm any HELD symbol that isn't in the ticker universe (a
            // position Wicker recorded, a CN ticker never searched). These show
            // in the Holdings list as surrogate rows with an empty series, so
            // without this they'd render flat ("no 涨跌") until first scrolled
            // into view — warming kicks the live fetch at launch so their price
            // + change populate like every other row.
            let known = Set(allTickers.map(\.symbol))
            for sym in Set(holdings.holdings.map(\.symbol)) where !known.contains(sym) {
                _ = store.series(for: sym,
                                 interval: .d1,
                                 fallback: CandleSeries(symbol: sym, interval: .d1, candles: []))
            }
            // Wire Wicker's portfolio.* tools over this window's live
            // HoldingsStore so the agent can read/write 持仓 (idempotent).
            agentRuntime.attachPortfolio(holdings)
            // NOTE: the validate-on-failure HoldingSymbolResolver is DISABLED.
            // It rewrote a holding's symbol on ANY fetch failure (incl. a
            // transient EastMoney throttle) using a loose Yahoo name search,
            // which mis-matched a wrong ticker and CORRUPTED the holding
            // (7666.HK / Metis → RO9.F). Mechanical canonicalisation + the
            // EastMoney→Yahoo chart fallback cover the real cases safely; a
            // best-effort fuzzy rename must never overwrite the user's symbol.
        }
        // Pin the native window tab bar visible even at one stock tab, so the
        // toolbar → tab-bar → content band is consistent (no "有时出现有时不
        // 出现"). Zero-size background reaches the hosting NSWindow.
        .background(AlwaysShowTabBar())
    }

    /// Symbols whose net signed quantity is ~0 — fully closed (平仓) but still
    /// carrying transaction history. Drives the Holdings list's "已平仓" marker
    /// and its sort-to-bottom ordering.
    static func closedSymbols(in holdings: [Holding]) -> Set<String> {
        let net = Dictionary(grouping: holdings, by: \.symbol)
            .mapValues { $0.reduce(0.0) { $0 + $1.signedQuantity } }
        return Set(net.filter { abs($0.value) < 1e-9 }.map(\.key))
    }

    /// Surrogate `Ticker`s for HELD symbols absent from the sample/custom
    /// universe (`allTickers`). The Holdings list shows these rows; the detail
    /// pane resolves a tapped row against `allTickers + these`, so a held-only
    /// symbol opens ITS page instead of falling back to allTickers[0]. Empty
    /// series → `LiveDataStore` fills live data on appear.
    static func heldSurrogateTickers(allTickers: [Ticker],
                                     holdings: [Holding]) -> [Ticker] {
        let knownIDs = Set(allTickers.map(\.id))
        var seen = Set<String>()
        return holdings.compactMap { h -> Ticker? in
            guard !knownIDs.contains(h.symbol),
                  seen.insert(h.symbol).inserted else { return nil }
            return Ticker(id: h.symbol, symbol: h.symbol, name: h.name, series: [:])
        }
    }

    /// Drop Yahoo results whose symbol is already in the watchlist —
    /// no point offering "+ Add" for AAPL when it's already there. The
    /// remaining list drives the Sidebar's "Search Results" section.
    private func remoteSearchResults(against existing: [Ticker])
        -> [YahooSearchResult]
    {
        let knownIDs = Set(existing.map(\.id))
        return searchResults.filter { !knownIDs.contains($0.symbol) }
    }

    /// Build a Ticker from a Yahoo search hit, append to `customTickers`
    /// if not present, and jump the selection to it. Empty synthetic
    /// series — `LiveDataStore` fills in real bars on first fetch.
    private func pickRemoteResult(_ r: YahooSearchResult) {
        if !customTickers.contains(where: { $0.id == r.symbol }) {
            customTickers.append(
                Ticker(id: r.symbol,
                       symbol: r.symbol,
                       name: r.displayName,
                       series: [:]))
            Self.saveCustomTickers(customTickers)
        }
        route = .ticker(r.symbol)
        searchQuery = ""
        searchResults = []
    }

    // MARK: - Custom ticker persistence

    /// Only the identity (symbol + name) is persisted. The heavy
    /// `series: [BarInterval: CandleSeries]` field is rebuilt from
    /// `LiveDataStore` on demand, so we never write candle blobs to
    /// UserDefaults.
    private struct PersistedTicker: Codable {
        let symbol: String
        let name: String
    }

    private static let customTickersKey = "wick.customTickers.v1"

    private static func loadCustomTickers() -> [Ticker] {
        guard let data = UserDefaults.standard.data(forKey: customTickersKey),
              let pairs = try? JSONDecoder().decode([PersistedTicker].self, from: data)
        else { return [] }
        return pairs.map { p in
            Ticker(id: p.symbol, symbol: p.symbol, name: p.name, series: [:])
        }
    }

    private static func saveCustomTickers(_ tickers: [Ticker]) {
        let pairs = tickers.map { PersistedTicker(symbol: $0.symbol, name: $0.name) }
        if let data = try? JSONEncoder().encode(pairs) {
            UserDefaults.standard.set(data, forKey: customTickersKey)
        }
    }

    /// Whether the floating Wicker composer should sit on top of the
    /// current route. Hidden on `.wicker` itself (workspace owns its
    /// own composer) — everywhere else it's the global chat entry.
    private var shouldShowFloatingComposer: Bool {
        switch route {
        case .wicker: return false
        default:      return true
        }
    }

    /// Symbol from the current route, threaded into a new chat
    /// session's `pinnedSymbol` so Wicker knows what the user was
    /// looking at when they typed. Nil on Portfolio / Market.
    private var selectedTickerIDForRoute: String? {
        if case .ticker(let id) = route { return id }
        return nil
    }

    /// Detail-tab picker. Lives in the window toolbar — segmented style
    /// is the native macOS / iOS expression for a 3–4 option switch.
    private func tabPicker(for ticker: Ticker) -> some View {
        Picker("Tab", selection: $tab) {
            // CN-only 资金 tab is hidden for non-CN tickers (see
            // DetailTab.tabs(for:)) so the toolbar picker matches the
            // in-pane picker in DetailView.header.
            ForEach(DetailTab.tabs(for: ticker)) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 380)
        .labelsHidden()
    }

    /// Case-insensitive substring match on either symbol or name. Empty
    /// query returns every ticker unchanged.
    private func filteredTickers(_ all: [Ticker]) -> [Ticker] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        let needle = q.lowercased()
        return all.filter {
            $0.symbol.lowercased().contains(needle)
                || $0.name.lowercased().contains(needle)
        }
    }
}
