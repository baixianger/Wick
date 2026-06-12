import SwiftUI
import CoreCharts
import IndicatorKit
import TradingFloor

// MARK: - Tab definition

enum DetailTab: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case chart    = "Chart"
    case news     = "News"
    case social   = "Social"
    case capital  = "资金"
    case shortInterest = "空头"
    case ai       = "AI"
    var id: String { rawValue }

    /// Localized tab label — `rawValue` stays fixed for `id`/persistence/gating.
    var label: String {
        switch self {
        case .overview:      return L("Overview", "概览")
        case .chart:         return L("Chart", "图表")
        case .news:          return L("News", "新闻")
        case .social:        return L("Social", "社交")
        case .capital:       return L("Capital", "资金")
        case .shortInterest: return L("Short", "空头")
        case .ai:            return L("AI", "AI")
        }
    }

    /// Tabs available for a given ticker. Two market-gated tabs are mutually
    /// exclusive:
    ///
    ///   • **资金** (CN-only): free EastMoney A-share / HK fund-flow +
    ///     financials + 龙虎榜 — shown only for tickers `CNSymbol.parse`
    ///     recognises.
    ///   • **空头** (US-only): free FINRA short-interest history — shown only
    ///     for bare US symbols (`AAPL` / `MSFT`): not CN/HK and carrying no
    ///     exchange-suffix dot (so intl listings like `VOD.L` / `BMW.DE` are
    ///     excluded too).
    ///
    /// A CN ticker sees 资金 (not 空头); a US ticker sees 空头 (not 资金); an
    /// international ticker sees neither.
    static func tabs(for ticker: Ticker) -> [DetailTab] {
        let symbol = ticker.symbol
        let isCN = CNSymbol.parse(symbol) != nil
        let isUS = !isCN && !symbol.contains(".")
        return allCases.filter {
            switch $0 {
            case .capital:       return isCN
            case .shortInterest: return isUS
            default:             return true
            }
        }
    }
}

// MARK: - Detail container

struct DetailView: View {
    let ticker: Ticker
    /// Owned by ContentView so the toolbar tab picker and the detail
    /// pane stay in sync, and so the picker survives ticker switches
    /// (which destroy DetailView via `.id(...)`).
    @Binding var tab: DetailTab
    /// Owned by ContentView so the toolbar's options menu can drive the
    /// Chart-tab pane layout (single vs side-by-side), and so the choice
    /// survives ticker switches that rebuild this view via `.id(...)`.
    @Binding var splitView: Bool
    /// Global indicator config — same reference type lives in ContentView
    /// so additions / removals / param edits flow into both Chart panes
    /// (and every ticker) without losing the user's setup on switches.
    let indicators: ChartIndicatorConfig
    /// User's buy/sell transactions. Per-ticker subset is rendered as
    /// markers on the per-ticker chart panes.
    let holdings: HoldingsStore
    /// Overview-tab range picker (Apple Stocks-style 11-option set).
    /// Drives the header subtitle + the consumer-facing area chart.
    @State private var range: OverviewRange = .m1
    /// Chart-tab time-resolution picker (5 coarse options — hour / day /
    /// week / month / all). Independent of `range`.
    @State private var chartScale: ChartScale = .d1
    /// Indicator-manager sheet state. Lives here (not ContentView)
    /// so we can drop the entire window toolbar on ticker routes —
    /// with `.hiddenTitleBar`, an empty toolbar collapses the
    /// chrome strip completely, recovering ~38pt of vertical space.
    @State private var indicatorSheetShown: Bool = false
    /// AI-tab analysis-history inspector state. Lifted up here (not
    /// inside `AITab`) because macOS `.inspector(isPresented:)` is a
    /// scene-level side column — when nested inside the outer
    /// ScrollView it broke vertical sizing of long reports. Attaching
    /// to the outer VStack (outside the ScrollView) is the only place
    /// where the inspector lays out correctly.
    @State private var historyOpen: Bool = false
    /// Selected historical report (by `generatedAt`). Lives at this
    /// level so the inspector content and `AITab`'s active-report
    /// rendering share one source of truth.
    @State private var historyExpanded: Date? = nil

    // Long-lived chart state for the Chart tab. `.id(ticker.id)` higher
    // up forces a fresh DetailView when the watchlist selection changes.
    //
    // Default `barSpacing: 8` — same across every freshly-created Chart
    // pane (1H / 1D / 1W / 1M / All), preserved across scale switches so
    // the user's pinch (or Cmd-scroll) zoom carries through. Each
    // coordinator owns its own density — side-by-side panes don't sync.
    @State private var coordinator = ChartCoordinator(
        timeScale: TimeScale(barSpacing: 8))
    @State private var engine = IndicatorEngine()
    @State private var coordinator2 = ChartCoordinator(
        timeScale: TimeScale(barSpacing: 8))
    @State private var engine2 = IndicatorEngine()
    @State private var chartScale2: ChartScale = .h1

    @Environment(LiveDataStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned chrome — the two-row header (ticker title + tab
            // picker + price column) stays anchored at top while tab
            // content scrolls below. Matches the pattern across
            // MarketView / PortfolioView for cross-page consistency.
            header
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Group {
                        switch tab {
                        case .overview:
                            OverviewTab(ticker: ticker,
                                        range: $range,
                                        holdings: holdings)
                        case .chart:
                            ChartTab(ticker: ticker,
                                     scale: $chartScale,
                                     scale2: $chartScale2,
                                     splitView: $splitView,
                                     coordinator: coordinator,
                                     coordinator2: coordinator2,
                                     engine: engine,
                                     engine2: engine2,
                                     indicators: indicators,
                                     holdings: holdings)
                        case .news:
                            NewsTab(ticker: ticker)
                        case .social:
                            SocialView(ticker: ticker)
                        case .capital:
                            CapitalView(ticker: ticker)
                        case .shortInterest:
                            ShortInterestView(ticker: ticker)
                        case .ai:
                            AITab(ticker: ticker,
                                  range: range,
                                  expanded: $historyExpanded,
                                  historyOpen: $historyOpen)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
            }
        }
        .background(appleBackground(for: colorScheme))
        .sheet(isPresented: $indicatorSheetShown) {
            IndicatorManagerView(config: indicators)
        }
        // History was previously a `.inspector(isPresented:)` side
        // column. macOS auto-injects its own toggle button alongside
        // any inspector, which duplicated the History pill in AITab
        // header and clutters the detail-pane chrome. AITab now owns
        // a two-column layout (report on the left, vertical history
        // on the right), gated by `historyOpen`.
        .onChange(of: tab) { _, new in
            if new != .ai { historyOpen = false }
        }
        // The `tab` binding is owned by ContentView and survives ticker
        // switches (DetailView is rebuilt via `.id`). If the previously
        // selected tab is no longer available for this ticker — e.g. was
        // `.capital` on a CN ticker, then switched to a US one — fall back
        // to Overview so we never render a stale / hidden tab.
        .onAppear {
            if !DetailTab.tabs(for: ticker).contains(tab) { tab = .overview }
        }
        .modifier(ChartStateBindings(
            ticker: ticker,
            indicators: indicators,
            holdings: holdings,
            coordinator: coordinator,
            coordinator2: coordinator2,
            engine: engine,
            engine2: engine2,
            chartScale: chartScale,
            chartScale2: chartScale2,
            store: store))
    }

    // MARK: - Header bits

    /// Two-row header that absorbs the tab picker (formerly in the
    /// window toolbar) — buys back the ~38pt vertical strip the
    /// toolbar used to occupy.
    ///
    /// Row 1 ("title section"): ticker symbol + name on the left,
    /// segmented tab picker on the right.
    /// Row 2 ("title sub")     : exchange + source badge on the left,
    /// dual-price columns on the right.
    private var header: some View {
        let trimmed = ticker.overviewSeries(range, store: store)
        let candles = trimmed.candles
        let lastPrice = candles.last?.close ?? ticker.lastPrice
        let basePrice = candles.first?.close ?? lastPrice
        let change = lastPrice - basePrice
        let changePct = basePrice == 0 ? 0 : (change / basePrice) * 100

        return VStack(alignment: .leading, spacing: 6) {
            // Title section row — ticker name on left, tab picker on
            // right. Chart tab also surfaces the Indicators icon button
            // beside the picker (chart-specific, sheet-triggering).
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ticker.symbol)
                        .font(.system(size: 32, weight: .bold))
                    Text(ticker.name)
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if tab == .chart {
                    Button {
                        indicatorSheetShown = true
                    } label: {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Indicators", "指标"))
                    .accessibilityLabel("Indicators")
                    .accessibilityIdentifier("ChartIndicatorsButton")
                }
                Picker("Tab", selection: $tab) {
                    ForEach(DetailTab.tabs(for: ticker)) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                // Widened from 280 → 340 to absorb the extra tabs (Social,
                // and the CN-only 资金 tab) without crowding the segments.
                .frame(width: 380)
                .labelsHidden()
            }
            // Title sub row — exchange + source badge on left,
            // dual prices on right.
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    Text("NASDAQ · USD")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    sourceBadge(active: range.underlyingInterval)
                }
                Spacer()
                priceColumn(value: lastPrice,
                            change: change,
                            changePct: changePct,
                            label: range.subtitle)
            }
        }
        // No horizontal padding here — the outer body's
        // .padding(.horizontal, 22) on the ScrollView VStack
        // covers the inset for the whole page consistently.
    }

    /// Single Apple-Stocks-style price column. The pre-market sibling
    /// was removed: Yahoo's free chart endpoint doesn't return pre/post
    /// quotes, so the column was being fabricated from a hash of the
    /// symbol — a UX red line in a real-money UI.
    private func priceColumn(value: Double,
                             change: Double,
                             changePct: Double,
                             label: String) -> some View
    {
        let isUp = change >= 0
        let tint: Color = isUp ? .green : .red
        let sign = isUp ? "+" : ""
        return VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.2f", value))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                HStack(spacing: 4) {
                    Text(sign + String(format: "%.2f", change))
                    Text(String(format: "(%@%.2f%%)", sign, changePct))
                        .opacity(0.85)
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }


    /// Live / error / loading state pill. The pill itself is a tinted
    /// Liquid Glass capsule — same shape across states, only the dot
    /// colour + accent change. Glass surface makes the badge breathe
    /// with whatever sits behind it (header, chart area) instead of
    /// feeling stamped on.
    @ViewBuilder
    private func sourceBadge(active: BarInterval) -> some View {
        switch store.source(for: ticker.symbol, interval: active) {
        case .live(let t):
            let secs = max(0, Int(Date().timeIntervalSince(t)))
            let label = secs < 60 ? L("Live · just now", "实时 · 刚刚") : L("Live · \(secs / 60)m ago", "实时 · \(secs / 60) 分钟前")
            badgePill(dot: .green, label: label, accent: .green)
        case .error:
            badgePill(dot: .orange, label: L("Demo · network unavailable", "演示 · 网络不可用"),
                       accent: .orange)
        case .retrying(let attempt):
            // Transient throttle / blip — backing off and retrying. Amber so
            // it reads as "working on it", not a hard failure.
            badgePill(dot: .yellow, label: L("Source unavailable · retrying (\(attempt))", "源暂不可用 · 重试中 (\(attempt))"),
                       accent: .yellow)
        case .unavailable:
            // Backoff spent. Honest "temporarily down" — the synthetic series
            // is what's on screen; revisiting the symbol re-arms a fetch.
            badgePill(dot: .red, label: L("Source unavailable · showing demo data", "源暂不可用 · 显示演示数据"),
                       accent: .red)
        case .demo:
            badgePill(dot: .secondary, label: L("Loading…  (Demo)", "加载中…（演示）"),
                       accent: .secondary)
        }
    }

    private func badgePill(dot: Color, label: String, accent: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(accent.opacity(0.95))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassEffect(.regular.tint(accent.opacity(0.18)), in: .capsule)
    }
}

// MARK: - Chart state bindings

/// Splits the per-chart `onAppear`/`onChange` cluster off `DetailView.body`
/// so the type-checker doesn't choke on the modifier chain.
private struct ChartStateBindings: ViewModifier {
    let ticker: Ticker
    let indicators: ChartIndicatorConfig
    let holdings: HoldingsStore
    let coordinator: ChartCoordinator
    let coordinator2: ChartCoordinator
    let engine: IndicatorEngine
    let engine2: IndicatorEngine
    let chartScale: ChartScale
    let chartScale2: ChartScale
    let store: LiveDataStore

    func body(content: Content) -> some View {
        content
            .onAppear {
                ChartTabState.configure(coordinator: coordinator,
                                         engine: engine,
                                         ticker: ticker,
                                         scale: chartScale,
                                         store: store,
                                         indicators: indicators,
                                         holdings: holdings)
                ChartTabState.configure(coordinator: coordinator2,
                                         engine: engine2,
                                         ticker: ticker,
                                         scale: chartScale2,
                                         store: store,
                                         indicators: indicators,
                                         holdings: holdings)
            }
            .onChange(of: indicators.instances) { _, _ in
                ChartTabState.syncIndicators(coordinator: coordinator, config: indicators)
                ChartTabState.syncIndicators(coordinator: coordinator2, config: indicators)
                engine.invalidateAll()
                engine2.invalidateAll()
            }
            .onChange(of: chartScale) { _, new in
                ChartTabState.apply(coordinator: coordinator, engine: engine,
                                    ticker: ticker, scale: new, store: store,
                                    holdings: holdings)
            }
            .onChange(of: chartScale2) { _, new in
                ChartTabState.apply(coordinator: coordinator2, engine: engine2,
                                    ticker: ticker, scale: new, store: store,
                                    holdings: holdings)
            }
            .onChange(of: store.source(for: ticker.symbol,
                                        interval: chartScale.underlyingInterval)) { _, _ in
                ChartTabState.apply(coordinator: coordinator, engine: engine,
                                    ticker: ticker, scale: chartScale, store: store,
                                    holdings: holdings)
            }
            .onChange(of: store.source(for: ticker.symbol,
                                        interval: chartScale2.underlyingInterval)) { _, _ in
                ChartTabState.apply(coordinator: coordinator2, engine: engine2,
                                    ticker: ticker, scale: chartScale2, store: store,
                                    holdings: holdings)
            }
            .onChange(of: holdings.holdings) { _, _ in
                ChartTabState.syncTransactionMarkers(coordinator: coordinator,
                                                      symbol: ticker.symbol,
                                                      holdings: holdings)
                ChartTabState.syncTransactionMarkers(coordinator: coordinator2,
                                                      symbol: ticker.symbol,
                                                      holdings: holdings)
            }
    }
}

// MARK: - Interval pill bar (shared by Overview + Chart)

struct IntervalPickerBar: View {
    @Binding var interval: IntervalOption

    var body: some View {
        LiquidGlassPillBar(items: IntervalOption.allCases,
                           selection: $interval) { item, isOn in
            Text(item.rawValue)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isOn ? .white : .secondary)
        }
    }
}

// MARK: - Apple-Stocks chart themes (light + dark)

/// Pick the right theme variant for the active color scheme. Both variants
/// keep the indicator palette / candle colours; only surface tones differ.
@MainActor
func appleTheme(for scheme: ColorScheme) -> ChartTheme {
    scheme == .dark ? appleDarkTheme : appleLightTheme
}

let appleDarkTheme: ChartTheme = {
    var t = ChartTheme.dark
    t.background = Color(white: 0.075)
    t.gridline = Color.white.opacity(0.06)
    t.axisLabel = Color(white: 0.65)
    t.candleUpStroke   = .green
    t.candleUpFill     = .green
    t.candleDownStroke = .red
    t.candleDownFill   = .red
    let blue = Color(red: 0.30, green: 0.62, blue: 0.95)
    t.lineStroke          = blue
    t.areaGradientTop     = blue.opacity(0.32)
    t.areaGradientBottom  = blue.opacity(0.00)
    t.indicatorPalette = applePalette
    return t
}()

let appleLightTheme: ChartTheme = {
    var t = ChartTheme.bright
    t.background = Color(white: 0.97)
    t.gridline = Color.black.opacity(0.06)
    t.axisLabel = Color(white: 0.30)
    t.candleUpStroke   = Color(red: 0.18, green: 0.78, blue: 0.36)
    t.candleUpFill     = Color(red: 0.18, green: 0.78, blue: 0.36)
    t.candleDownStroke = Color(red: 0.92, green: 0.20, blue: 0.30)
    t.candleDownFill   = Color(red: 0.92, green: 0.20, blue: 0.30)
    let blue = Color(red: 0.18, green: 0.45, blue: 0.92)
    t.lineStroke          = blue
    t.areaGradientTop     = blue.opacity(0.28)
    t.areaGradientBottom  = blue.opacity(0.00)
    t.indicatorPalette = applePalette
    return t
}()

private let applePalette: [Color] = [
    Color(red: 0.95, green: 0.75, blue: 0.10),  // SMA(5)
    Color(red: 0.20, green: 0.55, blue: 0.90),  // SMA(10)
    Color(red: 0.78, green: 0.30, blue: 0.78),  // SMA(20)
    Color(red: 0.10, green: 0.70, blue: 0.42),
    Color(red: 0.90, green: 0.45, blue: 0.15),
    Color(red: 0.35, green: 0.55, blue: 0.95),
    Color(red: 0.55, green: 0.55, blue: 0.55),
    Color(red: 0.40, green: 0.40, blue: 0.40),
]

/// Background tone for the detail pane / sidebar surrounds, matching the
/// active scheme. Apple Stocks uses an off-white / off-black backdrop.
func appleBackground(for scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(white: 0.075) : Color(white: 0.97)
}
