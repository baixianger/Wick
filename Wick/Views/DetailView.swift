import SwiftUI
import CoreCharts
import IndicatorKit

// MARK: - Tab definition

enum DetailTab: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case chart    = "Chart"
    case news     = "News"
    case ai       = "AI"
    var id: String { rawValue }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
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
                    case .ai:
                        AITab(ticker: ticker, range: range)
                    }
                }
                .padding(.bottom, 24)
            }
            // Unified page padding — Portfolio is the reference
            // (.horizontal 22, .vertical 18). Header had its own
            // .padding(.horizontal, 16) before; consolidated into
            // this single outer call so every page edges in by the
            // same amount.
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .background(appleBackground(for: colorScheme))
        .sheet(isPresented: $indicatorSheetShown) {
            IndicatorManagerView(config: indicators)
        }
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
        // Re-attach when Yahoo data lands for either pane's interval.
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
        // Synthetic pre-market — Yahoo's free chart endpoint doesn't expose
        // it, so we wiggle the last close by ±0.5% with a stable per-symbol
        // sign. Apple Stocks shows two columns; without a fake here the
        // right side would look empty next to its layout.
        let pmOffset = preMarketOffset(symbol: ticker.symbol, last: lastPrice)
        let preMarketPrice = lastPrice + pmOffset

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
                    .help("Indicators")
                }
                Picker("Tab", selection: $tab) {
                    ForEach(DetailTab.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
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
                HStack(alignment: .top, spacing: 24) {
                    priceColumn(value: lastPrice, change: change, label: "At Close",
                                emphasized: true)
                    priceColumn(value: preMarketPrice, change: pmOffset,
                                label: "Pre-Market", emphasized: false)
                }
            }
        }
        // No horizontal padding here — the outer body's
        // .padding(.horizontal, 22) on the ScrollView VStack
        // covers the inset for the whole page consistently.
    }

    /// One column of the Apple Stocks-style dual price header.
    @ViewBuilder
    private func priceColumn(value: Double, change: Double,
                             label: String, emphasized: Bool) -> some View
    {
        let isUp = change >= 0
        let tint: Color = isUp ? .green : .red
        VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.2f", value))
                    .font(.system(size: emphasized ? 24 : 18,
                                  weight: .bold, design: .rounded))
                Text((isUp ? "+" : "") + String(format: "%.2f", change))
                    .font(.system(size: emphasized ? 14 : 12,
                                  weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// Deterministic ±0.5% offset per symbol so the pre-market column
    /// shows a stable price across re-renders (instead of jittering on
    /// every body refresh).
    private func preMarketOffset(symbol: String, last: Double) -> Double {
        let hash = symbol.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let signed = (hash % 7) - 3       // -3 ... +3
        return last * Double(signed) / 1000.0   // ±0.3%
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
            let label = secs < 60 ? "Live · just now" : "Live · \(secs / 60)m ago"
            badgePill(dot: .green, label: label, accent: .green)
        case .error:
            badgePill(dot: .orange, label: "Demo · network unavailable",
                       accent: .orange)
        case .demo:
            badgePill(dot: .secondary, label: "Loading…  (Demo)",
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
