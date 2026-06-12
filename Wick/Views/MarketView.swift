import SwiftUI
import CoreCharts
import IndicatorKit

/// "What's the world doing" surface. Top-level asset-class selector
/// lets the user pivot between six worlds without leaving the page:
///
///   US · Asia Pacific · Europe · Crypto · Commodities · Macro
///
/// Each tab renders a cards grid for that asset class; clicking any
/// card opens its K-line + the user's configured indicators directly
/// below. The US tab carries the extra Apple-Stocks-style chrome we
/// already had — sector heatmap, watchlist movers, headlines — because
/// it's our reference market and we don't want to throw that away.
///
/// Per the UX model, Market is *passive* — there's no chat input here.
/// The floating Wicker composer that sits over every non-Wicker page
/// handles all "ask the agent" interactions.
struct MarketView: View {

    /// Universe used to populate the US-tab Movers section. The parent
    /// (ContentView) passes `Ticker.samples + customTickers` so any
    /// ticker the user has added through search is eligible.
    let universe: [Ticker]

    /// Global indicator config — same reference type lives in
    /// ContentView so additions / removals / param edits flow into
    /// the Market chart pane (and every per-ticker chart) without
    /// losing the user's setup.
    let indicators: ChartIndicatorConfig

    @Environment(LiveDataStore.self) private var store
    @Environment(FredDataStore.self) private var fredStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var assetClass: MarketAssetClass = .us
    @State private var macroCategory: MacroCategory = .rates
    @State private var moverTab: MoverTab = .gainers
    /// Per-asset-class card selection so each tab remembers its own
    /// active card across tab switches.
    @State private var selectedByClass: [MarketAssetClass: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned chrome — page title + tab selector stay anchored
            // at the top while content underneath scrolls. Apple
            // Stocks / Google Finance / Webull all park their nav this
            // way; otherwise the user has to scroll back up just to
            // switch markets after browsing one.
            VStack(alignment: .leading, spacing: 14) {
                header
                tabBar
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider().opacity(0.4)

            // Scrollable content area
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    tabContent
                    Color.clear.frame(height: 72) // composer safe area
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appleBackground(for: colorScheme))
        .onAppear { warmTab(assetClass) }
        .onChange(of: assetClass) { _, new in warmTab(new) }
    }

    // MARK: - Header & tabs

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Market")
                .font(.system(size: 32, weight: .bold))
            Text(headerSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var headerSubtitle: String {
        let date = Date.now.formatted(date: .complete, time: .omitted)
        return "\(date) · \(assetClass.subtitle)"
    }

    private var tabBar: some View {
        FlatPicker(items: MarketAssetClass.allCases,
                   selection: $assetClass,
                   layout: .compact)
    }

    // MARK: - Per-tab content

    @ViewBuilder
    private var tabContent: some View {
        let specs = assetClass.specs()
        VStack(alignment: .leading, spacing: 22) {
            // Macro has no K-line drilldown (FRED series aren't candles), so
            // instead of the horizontal card rail it gets a dashboard LIST —
            // one indicator per row with its own inline chart (line for
            // levels/rates, bar for monthly/quarterly flows). Every other class
            // keeps the flick-able card rail + chart pane.
            if assetClass == .macro {
                macroSection(specs)
            } else {
                cardsGrid(specs)
                if let active = activeSpec(in: specs) {
                    MarketChartPane(spec: active, indicators: indicators)
                }
            }
            if assetClass == .us {
                sectorSection
                moversSection
                earningsSection
                newsSection
            }
            if assetClass == .macro {
                macroDisclosureRow
            }
        }
    }

    /// Horizontally-scrolling card rail. Replaces the earlier
    /// `LazyVGrid` (which wrapped to a second row at 6+ cards) per
    /// the Google Finance / Webull pattern — every market is "one
    /// strip you can flick left/right." Negative outer horizontal
    /// padding breaks out of the parent VStack's 22-pt inset so the
    /// scroll track itself spans the full detail-pane width (cards
    /// can scroll edge-to-edge); the inner HStack restores the 22-pt
    /// gutter so the leading card still aligns with the page's text
    /// margin when the rail is parked at the start.
    private func cardsGrid(_ specs: [IndexSpec]) -> some View {
        let cardWidth: CGFloat = assetClass == .macro ? 200 : 195
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(specs) { spec in
                    IndexCardView(
                        spec: spec,
                        series: seriesFor(spec),
                        selected: spec.symbol == selectedByClass[assetClass],
                        onTap: { selectedByClass[assetClass] = spec.symbol }
                    )
                    .frame(width: cardWidth)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 2)  // breathing room for selection ring stroke
        }
        .padding(.horizontal, -22)
    }

    /// Macro dashboard: a category SUB-TAB (Rates / Inflation / Labor / Growth)
    /// over a detailed per-indicator list. Picking a tab shows only that group's
    /// indicators, each as one full-width row — name + latest value + change up
    /// top, a larger chart below (line for levels/rates, +/- bars for the
    /// discrete monthly/quarterly flows). With only a few items per tab there's
    /// room for a real chart per indicator instead of a tiny sparkline.
    private func macroSection(_ specs: [IndexSpec]) -> some View {
        let bySymbol = Dictionary(specs.map { ($0.symbol, $0) },
                                  uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: 16) {
            FlatPicker(items: MacroCategory.allCases,
                       selection: $macroCategory,
                       layout: .compact)
            VStack(spacing: 0) {
                let symbols = macroCategory.symbols
                ForEach(symbols, id: \.self) { sym in
                    if let spec = bySymbol[sym] {
                        MacroDetailRow(spec: spec,
                                       series: seriesFor(spec),
                                       isBar: Self.barMacroSymbols.contains(sym))
                        if sym != symbols.last { Divider().opacity(0.4) }
                    }
                }
            }
            .liquidGlass(cornerRadius: 14)
        }
    }

    /// Macro series that render as bars (discrete period flows, sign matters):
    /// monthly Nonfarm-Payroll adds + quarterly Real-GDP growth.
    static let barMacroSymbols: Set<String> = ["PAYEMS", "A191RL1Q225SBEA"]

    /// Pick the right cache per asset class — FRED for macro series
    /// IDs, Yahoo via `LiveDataStore` for everything else. CPI uses
    /// the `pc1` units transform so the displayed value is "% change
    /// from year ago" (Wall Street CPI YoY), matching what the agent
    /// surfaces in `FredClient.macroSummary()`.
    private func seriesFor(_ spec: IndexSpec) -> CandleSeries {
        if assetClass == .macro {
            // Units come from the spec now (CPI/Core-PCE/etc. → `pc1` YoY,
            // Nonfarm Payrolls → `chg` monthly adds); default `lin` for levels.
            let units = spec.fredUnits ?? "lin"
            return fredStore.series(for: spec.symbol,
                                     units: units,
                                     fallback: spec.fallbackSeries)
        }
        return store.series(for: spec.symbol,
                            interval: .d1,
                            fallback: spec.fallbackSeries)
    }

    /// Currently active spec for the open tab. Falls back to the
    /// first spec so the chart pane is non-empty on first appearance
    /// (and a fresh tab switch always has something selected).
    private func activeSpec(in specs: [IndexSpec]) -> IndexSpec? {
        if let sym = selectedByClass[assetClass],
           let hit = specs.first(where: { $0.symbol == sym }) {
            return hit
        }
        return specs.first
    }

    // MARK: - US-only sections (sectors / movers / news)

    private var sectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sectors")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("SPDR sector ETFs · color ∝ today's change")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            TreemapView(tiles: sectorTiles(), minLabelArea: 900)
                .chartTheme(appleTheme(for: colorScheme))
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func sectorTiles() -> [HeatTile] {
        MarketSpec.sectors.map { spec in
            let series = store.series(for: spec.symbol,
                                       interval: .d1,
                                       fallback: spec.fallbackSeries)
            let snap = IndexSnapshot(series: series)
            return HeatTile(id: spec.symbol,
                            label: spec.shortName,
                            secondary: spec.symbol,
                            changePct: snap.changePct,
                            weight: spec.weight)
        }
    }

    private enum MoverTab: String, CaseIterable, Identifiable, Hashable {
        case gainers     = "Gainers"
        case losers      = "Losers"
        case mostActive  = "Most Active"
        var id: String { rawValue }
    }

    private var moversSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Movers")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(universe.count) tickers in watchlist")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            FlatPicker(items: MoverTab.allCases,
                       selection: $moverTab,
                       layout: .compact)
            VStack(spacing: 0) {
                let rows = moverRows()
                if rows.isEmpty {
                    Text("Add tickers to the watchlist to populate movers.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(rows) { row in
                        moverRow(row)
                            .padding(.vertical, 8)
                        Divider().opacity(0.35)
                    }
                }
            }
        }
    }

    private struct MoverRow: Identifiable, Hashable {
        let symbol: String
        let name: String
        let last: Double
        let change: Double
        let changePct: Double
        let volume: Double
        var id: String { symbol }
    }

    private func moverRows() -> [MoverRow] {
        let raw: [MoverRow] = universe.compactMap { t in
            let s = t.liveSeries(.d1, store: store)
            guard let last = s.candles.last,
                  s.candles.count >= 2 else { return nil }
            let prev = s.candles[s.candles.count - 2].close
            let change = last.close - prev
            let pct = prev == 0 ? 0 : (change / prev) * 100
            return MoverRow(symbol: t.symbol, name: t.name,
                            last: last.close, change: change,
                            changePct: pct, volume: last.volume)
        }
        switch moverTab {
        case .gainers:
            return raw.filter { $0.changePct > 0 }
                      .sorted { $0.changePct > $1.changePct }
                      .prefix(8).map { $0 }
        case .losers:
            return raw.filter { $0.changePct < 0 }
                      .sorted { $0.changePct < $1.changePct }
                      .prefix(8).map { $0 }
        case .mostActive:
            return raw.sorted { $0.volume * $0.last > $1.volume * $1.last }
                      .prefix(8).map { $0 }
        }
    }

    private func moverRow(_ r: MoverRow) -> some View {
        let tint: Color = r.changePct >= 0 ? .green : .red
        let sign = r.changePct >= 0 ? "+" : ""
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(r.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.2f", r.last))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("\(sign)\(String(format: "%.2f", r.change))")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .trailing)
            Text("\(sign)\(String(format: "%.2f", r.changePct))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(tint))
                .frame(width: 78, alignment: .trailing)
        }
    }

    // MARK: - Earnings calendar (US tab)

    /// Synthetic upcoming-earnings list. Real Yahoo/Finnhub calendar
    /// wiring is Phase 2 — for now the static fixture gives the
    /// section shape so the page looks "alive." Footer note tells
    /// the user this is preview-only.
    private var earningsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Upcoming Earnings")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Next 10 days · preview")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 0) {
                ForEach(MarketSpec.upcomingEarnings) { row in
                    earningsRow(row)
                        .padding(.vertical, 8)
                    Divider().opacity(0.35)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("Preview data. Live earnings calendar needs a Finnhub key in Settings → Agents.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
    }

    private func earningsRow(_ r: EarningsEntry) -> some View {
        HStack(spacing: 14) {
            // Date column — month + day in compact stack so the
            // table reads at a glance.
            VStack(spacing: 0) {
                Text(r.monthLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(r.day)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
            .frame(width: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(r.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("EPS est.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("$\(String(format: "%.2f", r.epsEstimate))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .frame(width: 70, alignment: .trailing)
            Text(r.timing.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(
                    Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                )
                .frame(width: 56, alignment: .trailing)
        }
    }

    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Headlines")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Across asset classes")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading,
                      spacing: 20) {
                ForEach(NewsFixtures.common) { item in
                    NewsRow(item: item, expanded: true)
                }
            }
        }
    }

    // MARK: - Macro tab footer

    /// Disclosure footer for the Macro tab. The macro symbols
    /// (`DGS10`, `FEDFUNDS`, etc.) are FRED IDs — not Yahoo tickers —
    /// so the existing `LiveDataStore` (Yahoo) won't ever return real
    /// data for them. They render with the synthetic GBM fallback for
    /// now; live FRED wiring slots in once a key is in Settings.
    private var macroDisclosureRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("Live FRED data when a key is set in Settings (synthetic preview otherwise). Tap a chart's Overlay to compare against another series or the US market.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 10)
    }

    // MARK: - Plumbing

    /// Warm the live cache for the tab the user just opened. Other
    /// tabs warm lazily on first visit — no need to spend bandwidth
    /// on classes the user never views.
    private func warmTab(_ tab: MarketAssetClass) {
        var specs = tab.specs()
        if tab == .us { specs += MarketSpec.sectors }
        for spec in specs {
            _ = store.series(for: spec.symbol,
                             interval: .d1,
                             fallback: spec.fallbackSeries)
        }
    }
}

// MARK: - Asset-class tab definition

/// Top-level tab selector for the Market page. Order here = order in
/// the picker. US sits first because Wick's reference design language
/// is Apple Stocks / NYSE-first; macro is last because it's currently
/// previewing synthetic numbers (live FRED wiring TBD).
/// Sub-tab categories inside the Macro asset class. `rawValue` is the tab
/// label (FlatPicker renders it); `symbols` is the FRED-id set shown when that
/// category is selected, in display order.
enum MacroCategory: String, CaseIterable, Identifiable, Hashable {
    case rates     = "Rates"
    case inflation = "Inflation"
    case labor     = "Labor"
    case growth    = "Growth"

    var id: String { rawValue }

    var symbols: [String] {
        switch self {
        case .rates:     return ["DGS10", "DGS2", "FEDFUNDS", "T10Y2Y"]
        case .inflation: return ["CPIAUCSL", "CPILFESL", "PCEPILFE"]
        case .labor:     return ["UNRATE", "PAYEMS", "ICSA"]
        case .growth:    return ["A191RL1Q225SBEA", "RSAFS"]
        }
    }
}

enum MarketAssetClass: String, CaseIterable, Identifiable, Hashable {
    case us           = "US"
    case asiaPacific  = "Asia Pacific"
    case europe       = "Europe"
    case crypto       = "Crypto"
    case commodities  = "Commodities"
    case forex        = "Forex"
    case macro        = "Macro"
    var id: String { rawValue }

    /// Header subtitle suffix for each tab — what the user is looking
    /// at this morning. Mirrors what mainstream apps show under their
    /// market-tab page title.
    var subtitle: String {
        switch self {
        case .us:          return "NYSE · NASDAQ"
        case .asiaPacific: return "Tokyo · Hong Kong · Shanghai · Seoul"
        case .europe:      return "London · Frankfurt · Paris"
        case .crypto:      return "Spot · USD pairs"
        case .commodities: return "Front-month futures · Metals · Energy"
        case .forex:       return "Major pairs · Spot"
        case .macro:       return "Rates · Inflation · Labor"
        }
    }

    func specs() -> [IndexSpec] {
        switch self {
        case .us:           return MarketSpec.indices
        case .asiaPacific:  return MarketSpec.globalIndices.filter { $0.region == .asiaPacific }
        case .europe:       return MarketSpec.globalIndices.filter { $0.region == .europe }
        case .crypto:       return MarketSpec.crypto
        case .commodities:  return MarketSpec.commodities
        case .forex:        return MarketSpec.forex
        case .macro:        return MarketSpec.macroIndicators
        }
    }
}

// MARK: - Shared index card

/// One Liquid Glass card shown in any of the tab grids. Tap → selects
/// (parent flips its `selectedByClass[…]`); the chart pane below the
/// grid mirrors that selection.
///
/// `series` is now passed in by the parent so the same view renders
/// against either `LiveDataStore` (Yahoo) or `FredDataStore` (FRED)
/// depending on which tab the card is showing — keeps the data
/// dispatch logic in one place (MarketView.seriesFor) and the card
/// itself store-agnostic.
fileprivate struct IndexCardView: View {
    let spec: IndexSpec
    let series: CandleSeries
    var selected: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        let snap = IndexSnapshot(series: series)
        let tint: Color = snap.isUp ? .green : .red

        let content = VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(spec.shortName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(spec.symbol)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text(formatNumber(snap.last))
                .font(.system(size: 20, weight: .bold, design: .rounded))
            HStack(spacing: 6) {
                Text(snap.changeString)
                Text(snap.changePctString)
                    .opacity(0.85)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            SparklineView(closes: snap.closes,
                          baseline: snap.closes.first ?? snap.last,
                          style: .area,
                          tint: tint,
                          lineWidth: 1.4)
                .frame(height: 26)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear,
                              lineWidth: 2)
        )
        .contentShape(Rectangle())

        return Group {
            if let onTap {
                Button(action: onTap) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private func formatNumber(_ v: Double) -> String {
        if abs(v) >= 1000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 2
            f.minimumFractionDigits = 2
            return f.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)
        }
        if abs(v) < 1 { return String(format: "%.4f", v) }
        return String(format: "%.2f", v)
    }
}

// MARK: - Macro dashboard row

/// One macro indicator as a DETAIL row: a header (name + FRED id + latest value
/// + change) over a full-width chart (line for levels/rates, +/- bars for
/// flows). With only a few indicators per category sub-tab there's room for a
/// proper chart per indicator, one to a row.
fileprivate struct MacroDetailRow: View {
    let spec: IndexSpec
    let series: CandleSeries
    let isBar: Bool

    @Environment(FredDataStore.self) private var fredStore
    @State private var overlay: MacroOverlay = .none

    var body: some View {
        let snap = IndexSnapshot(series: series)
        let tint: Color = snap.isUp ? .green : .red
        // Resolve the overlay series through the same FRED cache as the primary.
        let overlaySeries: CandleSeries? = overlay.fred.map { f in
            fredStore.series(for: f.id, units: f.units,
                             fallback: Fixtures.gbm(n: 120, seed: 99,
                                                    mu: 0, sigma: 0.01,
                                                    startPrice: overlay.fallbackLevel,
                                                    symbol: f.id, interval: .d1))
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.shortName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(spec.symbol)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.format(snap.last))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        Text(snap.changeString)
                        Text(snap.changePctString).opacity(0.85)
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                }
            }
            MacroOverlayChart(primary: series,
                              primaryIsBar: isBar,
                              primaryTint: tint,
                              overlay: overlaySeries,
                              overlayColor: overlay.color)
                .frame(maxWidth: .infinity)
                .frame(height: 88)
            // Overlay picker + legend.
            HStack(spacing: 8) {
                if overlay != .none {
                    Circle().fill(overlay.color).frame(width: 7, height: 7)
                    Text(overlay.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Picker("Overlay", selection: $overlay) {
                        ForEach(MacroOverlay.allCases) { o in
                            Text(o.rawValue).tag(o)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                        Text(overlay == .none ? "Overlay" : "Change")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(16)
        .contentShape(Rectangle())
    }

    /// Compact value: thousands grouped, sub-1 to 2 dp, else 2 dp; a leading
    /// `+` for positive flow prints reads naturally next to a bar chart.
    static func format(_ v: Double) -> String {
        if abs(v) >= 1000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal; f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v)
        }
        if abs(v) < 1 { return String(format: "%.2f", v) }
        return String(format: "%.1f", v)
    }
}

/// What a macro chart can overlay for comparison: another macro series, or the
/// broad US stock market. Each resolves to a FRED id + units (so it goes
/// through the same `FredDataStore` path as the primary). "Total Market" is the
/// Wilshire 5000 — the most comprehensive US equity index ("最全").
fileprivate enum MacroOverlay: String, CaseIterable, Identifiable {
    case none        = "None"
    case sp500       = "S&P 500"
    case nasdaq      = "Nasdaq Comp"
    case dow         = "Dow"
    case cpi         = "CPI YoY"
    case corePCE     = "Core PCE"
    case fedFunds    = "Fed Funds"
    case tenYear     = "10Y Yield"
    case unemployment = "Unemployment"

    var id: String { rawValue }

    /// FRED series id + units, or nil for `.none`.
    var fred: (id: String, units: String)? {
        switch self {
        case .none:         return nil
        case .sp500:        return ("SP500", "lin")
        case .nasdaq:       return ("NASDAQCOM", "lin")
        case .dow:          return ("DJIA", "lin")
        case .cpi:          return ("CPIAUCSL", "pc1")
        case .corePCE:      return ("PCEPILFE", "pc1")
        case .fedFunds:     return ("FEDFUNDS", "lin")
        case .tenYear:      return ("DGS10", "lin")
        case .unemployment: return ("UNRATE", "lin")
        }
    }

    /// Synthetic fallback level so the overlay isn't a flat 0 before FRED loads.
    var fallbackLevel: Double {
        switch self {
        case .sp500: return 5200; case .nasdaq: return 18000; case .dow: return 42000
        case .cpi: return 3.2; case .corePCE: return 2.8
        case .fedFunds: return 5.25; case .tenYear: return 4.3
        case .unemployment: return 4.0; case .none: return 0
        }
    }

    /// Overlay line colour — a contrasting accent against the primary's tint.
    var color: Color { .purple }
}

/// Chart that draws a macro PRIMARY series (line or +/- bars) and, optionally, a
/// second OVERLAY series on its OWN independent vertical scale (the two have
/// wildly different ranges — e.g. payroll adds vs the S&P level). The overlay is
/// **date-aligned** to the primary's bar times (sampled at-or-before each date),
/// so they line up in time even at different frequencies; where the overlay has
/// no data for an early date it simply isn't drawn there.
fileprivate struct MacroOverlayChart: View {
    let primary: CandleSeries
    let primaryIsBar: Bool
    let primaryTint: Color
    let overlay: CandleSeries?
    let overlayColor: Color

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let bars = Array(primary.candles.suffix(60))
            guard !bars.isEmpty, size.width > 0, size.height > 0 else { return }
            let times = bars.map(\.time)
            let n = bars.count

            // ── Primary ──
            let pv = bars.map(\.close)
            if primaryIsBar {
                drawBars(pv, in: &ctx, size: size, color: primaryTint)
            } else {
                drawLine(pv.map { Optional($0) }, in: &ctx, size: size,
                         color: primaryTint, width: 1.6, fill: true)
            }

            // ── Overlay (independent scale, date-aligned) ──
            if let overlay {
                let aligned = Self.align(Array(overlay.candles), to: times)
                drawLine(aligned, in: &ctx, size: size,
                         color: overlayColor, width: 1.4, fill: false)
            }
            _ = n
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Sample `candles` at-or-before each target time (step-hold), giving one
    /// value per target date (nil before the overlay's history starts).
    static func align(_ candles: [Candle], to times: [Date]) -> [Double?] {
        let ov = candles.sorted { $0.time < $1.time }
        var out: [Double?] = []
        var j = 0
        var last: Double? = nil
        for t in times {
            while j < ov.count && ov[j].time <= t { last = ov[j].close; j += 1 }
            out.append(last)
        }
        return out
    }

    private func drawLine(_ values: [Double?], in ctx: inout GraphicsContext,
                          size: CGSize, color: Color, width: CGFloat, fill: Bool) {
        let present = values.compactMap { $0 }
        guard let lo = present.min(), let hi = present.max() else { return }
        let range = max(hi - lo, 0.0001)
        let n = values.count
        func pt(_ i: Int, _ v: Double) -> CGPoint {
            let x = n <= 1 ? size.width / 2 : size.width * CGFloat(i) / CGFloat(n - 1)
            let y = size.height - CGFloat((v - lo) / range) * (size.height - 2) - 1
            return CGPoint(x: x, y: y)
        }
        var path = Path()
        var started = false
        for (i, v) in values.enumerated() {
            guard let v else { started = false; continue }
            let p = pt(i, v)
            if started { path.addLine(to: p) } else { path.move(to: p); started = true }
        }
        if fill {
            var area = path
            // close down to the baseline for a soft fill
            if let lastIdx = values.lastIndex(where: { $0 != nil }),
               let firstIdx = values.firstIndex(where: { $0 != nil }) {
                area.addLine(to: CGPoint(x: pt(lastIdx, values[lastIdx]!).x, y: size.height))
                area.addLine(to: CGPoint(x: pt(firstIdx, values[firstIdx]!).x, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.22), color.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)))
            }
        }
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private func drawBars(_ values: [Double], in ctx: inout GraphicsContext,
                          size: CGSize, color: Color) {
        let lo = min(0, values.min() ?? 0)
        let hi = max(0, values.max() ?? 0)
        let range = max(hi - lo, 0.0001)
        func y(_ v: Double) -> CGFloat { size.height - CGFloat((v - lo) / range) * size.height }
        let zeroY = y(0)
        let gap: CGFloat = 1.5
        let n = values.count
        let barW = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * (barW + gap)
            let top = min(zeroY, y(v))
            let h = max(0.5, abs(zeroY - y(v)))
            ctx.fill(Path(roundedRect: CGRect(x: x, y: top, width: barW, height: h),
                          cornerRadius: min(1.5, barW / 2)),
                     with: .color(v >= 0 ? .green : .red))
        }
        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: zeroY))
        zero.addLine(to: CGPoint(x: size.width, y: zeroY))
        ctx.stroke(zero, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
    }
}

/// Inline +/- bar chart off a zero baseline (positive green, negative red).
/// For discrete period flows (Nonfarm Payrolls, GDP) where each bar is one
/// month/quarter's print and the sign is meaningful.
fileprivate struct MacroBarSparkline: View {
    let values: [Double]

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            // Cap to the most recent ~26 prints so bars stay legible.
            let vals = Array(values.suffix(26))
            guard !vals.isEmpty, size.width > 0, size.height > 0 else { return }
            let lo = min(0, vals.min() ?? 0)
            let hi = max(0, vals.max() ?? 0)
            let range = max(hi - lo, 0.0001)
            func y(_ v: Double) -> CGFloat {
                size.height - CGFloat((v - lo) / range) * size.height
            }
            let zeroY = y(0)
            let gap: CGFloat = 1.5
            let n = vals.count
            let barW = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            for (i, v) in vals.enumerated() {
                let x = CGFloat(i) * (barW + gap)
                let top = min(zeroY, y(v))
                let h = max(0.5, abs(zeroY - y(v)))
                let rect = CGRect(x: x, y: top, width: barW, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(1.5, barW / 2)),
                         with: .color(v >= 0 ? .green : .red))
            }
            // Zero baseline.
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: zeroY))
            zero.addLine(to: CGPoint(x: size.width, y: zeroY))
            ctx.stroke(zero, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Chart pane below the cards

/// K-line + the user's configured indicators for whichever card is
/// active in the parent tab. Reuses `ChartTabState` so this view
/// behaves identically to DetailView's Chart tab (same coordinator,
/// same indicator engine, same theme) — meaning indicators added in
/// IndicatorManagerView flow in here without ceremony.
private struct MarketChartPane: View {

    let spec: IndexSpec
    let indicators: ChartIndicatorConfig

    @Environment(LiveDataStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    @State private var scale: ChartScale = .d1
    @State private var coordinator = ChartCoordinator(
        timeScale: TimeScale(barSpacing: 8))
    @State private var engine = IndicatorEngine()

    var body: some View {
        let surrogate = spec.makeTickerSurrogate()
        let theme = appleTheme(for: colorScheme)
        let series = surrogate.liveSeries(scale.underlyingInterval, store: store)

        VStack(alignment: .leading, spacing: 10) {
            // Pane header — selected symbol's name + symbol on left,
            // scale picker (1H / 1D / 1W / 1M / All) on right.
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.shortName)
                        .font(.system(size: 16, weight: .semibold))
                    Text(spec.symbol)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                FlatPicker(items: ChartScale.allCases,
                           selection: $scale,
                           font: .system(size: 12, weight: .semibold,
                                         design: .rounded),
                           layout: .compact)
            }

            ZStack(alignment: .topLeading) {
                CandleChartView(series: series,
                                style: .candle,
                                showVolume: true,
                                allowGestures: true,
                                showLastPriceTag: true,
                                coordinator: coordinator)
                IndicatorOverlay(coordinator: coordinator, engine: engine)
            }
            .chartTheme(theme)
            .frame(minHeight: 360)
            .crosshairHover(coordinator: coordinator)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .onAppear {
            ChartTabState.configure(coordinator: coordinator,
                                    engine: engine,
                                    ticker: surrogate,
                                    scale: scale,
                                    store: store,
                                    indicators: indicators)
        }
        .onChange(of: spec.symbol) { _, _ in
            ChartTabState.apply(coordinator: coordinator,
                                engine: engine,
                                ticker: spec.makeTickerSurrogate(),
                                scale: scale,
                                store: store)
        }
        .onChange(of: scale) { _, new in
            ChartTabState.apply(coordinator: coordinator,
                                engine: engine,
                                ticker: spec.makeTickerSurrogate(),
                                scale: new,
                                store: store)
        }
        .onChange(of: indicators.instances) { _, _ in
            ChartTabState.syncIndicators(coordinator: coordinator,
                                         config: indicators)
            engine.invalidateAll()
        }
    }
}

// MARK: - Index / sector catalogue

/// Macro grouping used to slice `globalIndices` into the Asia
/// Pacific / Europe / Americas tabs.
enum IndexRegion: String, CaseIterable, Identifiable, Hashable {
    case asiaPacific = "Asia Pacific"
    case europe      = "Europe"
    case americas    = "Americas"
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

/// Hand-curated catalogue for the Market page. Symbols, display names,
/// and synthetic-fallback seed parameters live together so the page
/// renders immediately with plausible numbers, then upgrades to live
/// data once `LiveDataStore` returns the Yahoo fetch.
struct IndexSpec: Identifiable, Hashable {
    let symbol: String
    let shortName: String
    let weight: Double           // sector weight (only used by sectors)
    let region: IndexRegion?     // only used by globalIndices
    let seed: UInt64
    let startPrice: Double
    let drift: Double
    let vol: Double
    /// FRED `units` transform for macro series (nil ⇒ `lin`, the raw level).
    /// `pc1` = % change from a year ago (inflation/growth YoY); `chg` = change
    /// from the prior period (e.g. monthly Nonfarm-Payroll adds). Ignored for
    /// non-macro (Yahoo) specs.
    let fredUnits: String?
    var id: String { symbol }

    init(symbol: String, shortName: String,
         weight: Double = 0,
         region: IndexRegion? = nil,
         seed: UInt64, startPrice: Double,
         drift: Double, vol: Double,
         fredUnits: String? = nil)
    {
        self.symbol = symbol
        self.shortName = shortName
        self.weight = weight
        self.region = region
        self.seed = seed
        self.startPrice = startPrice
        self.drift = drift
        self.vol = vol
        self.fredUnits = fredUnits
    }
}

extension IndexSpec {

    var fallbackSeries: CandleSeries {
        Fixtures.gbm(n: 90,
                     seed: seed,
                     mu: drift,
                     sigma: vol,
                     startPrice: startPrice,
                     symbol: symbol,
                     interval: .d1)
    }

    /// Minimal `Ticker` wrapping this spec — the chart pipeline keys
    /// off `Ticker` for live-series lookup, so we synthesise one per
    /// non-watchlist symbol here rather than forking the API.
    func makeTickerSurrogate() -> Ticker {
        Ticker(id: symbol,
               symbol: symbol,
               name: shortName,
               series: [.d1: fallbackSeries])
    }
}

enum MarketSpec {

    /// Five headline US benchmarks every retail investing app shows
    /// at the top of the Market tab. `^RUT` and `^VIX` round out the
    /// large-cap trio with breadth + risk-sentiment context.
    static let indices: [IndexSpec] = [
        IndexSpec(symbol: "^GSPC", shortName: "S&P 500",
                  seed: 1001, startPrice: 5200, drift: 0.0003, vol: 0.008),
        IndexSpec(symbol: "^IXIC", shortName: "Nasdaq",
                  seed: 1002, startPrice: 16500, drift: 0.0004, vol: 0.011),
        IndexSpec(symbol: "^DJI",  shortName: "Dow",
                  seed: 1003, startPrice: 38500, drift: 0.0002, vol: 0.007),
        IndexSpec(symbol: "^RUT",  shortName: "Russell 2000",
                  seed: 1004, startPrice: 2100,  drift: 0.0001, vol: 0.012),
        IndexSpec(symbol: "^VIX",  shortName: "VIX",
                  seed: 1005, startPrice: 14.5, drift: -0.0002, vol: 0.05),
    ]

    /// Eleven GICS sector buckets mapped to SPDR sector ETFs. Weights
    /// are static approximations of S&P 500 sector market-cap shares —
    /// they only influence treemap cell area, not the prices/colour
    /// (which come from each ETF's live daily candle).
    static let sectors: [IndexSpec] = [
        IndexSpec(symbol: "XLK",  shortName: "Tech",          weight: 0.295,
                  seed: 2001, startPrice: 230, drift: 0.0005, vol: 0.013),
        IndexSpec(symbol: "XLF",  shortName: "Financials",    weight: 0.135,
                  seed: 2002, startPrice: 48,  drift: 0.0002, vol: 0.011),
        IndexSpec(symbol: "XLV",  shortName: "Health Care",   weight: 0.115,
                  seed: 2003, startPrice: 145, drift: 0.0001, vol: 0.010),
        IndexSpec(symbol: "XLY",  shortName: "Discretionary", weight: 0.105,
                  seed: 2004, startPrice: 215, drift: 0.0003, vol: 0.013),
        IndexSpec(symbol: "XLC",  shortName: "Comm Svcs",     weight: 0.090,
                  seed: 2005, startPrice: 95,  drift: 0.0003, vol: 0.012),
        IndexSpec(symbol: "XLI",  shortName: "Industrials",   weight: 0.080,
                  seed: 2006, startPrice: 138, drift: 0.0002, vol: 0.010),
        IndexSpec(symbol: "XLP",  shortName: "Staples",       weight: 0.060,
                  seed: 2007, startPrice: 81,  drift: 0.0001, vol: 0.008),
        IndexSpec(symbol: "XLE",  shortName: "Energy",        weight: 0.040,
                  seed: 2008, startPrice: 92,  drift: 0.0001, vol: 0.016),
        IndexSpec(symbol: "XLU",  shortName: "Utilities",     weight: 0.025,
                  seed: 2009, startPrice: 75,  drift: 0.0001, vol: 0.009),
        IndexSpec(symbol: "XLB",  shortName: "Materials",     weight: 0.025,
                  seed: 2010, startPrice: 88,  drift: 0.0001, vol: 0.011),
        IndexSpec(symbol: "XLRE", shortName: "Real Estate",   weight: 0.030,
                  seed: 2011, startPrice: 42,  drift: 0.0001, vol: 0.011),
    ]

    /// Ten spot-USD crypto pairs — top names by market cap excluding
    /// stablecoins. Yahoo's `BTC-USD` notation is its native crypto
    /// symbol format; works through the existing `LiveDataStore`
    /// path with no adapter changes.
    static let crypto: [IndexSpec] = [
        IndexSpec(symbol: "BTC-USD",  shortName: "Bitcoin",
                  seed: 3001, startPrice: 95000, drift: 0.0008, vol: 0.025),
        IndexSpec(symbol: "ETH-USD",  shortName: "Ethereum",
                  seed: 3002, startPrice: 3500,  drift: 0.0006, vol: 0.030),
        IndexSpec(symbol: "SOL-USD",  shortName: "Solana",
                  seed: 3003, startPrice: 180,   drift: 0.0005, vol: 0.045),
        IndexSpec(symbol: "BNB-USD",  shortName: "BNB",
                  seed: 3004, startPrice: 580,   drift: 0.0005, vol: 0.030),
        IndexSpec(symbol: "XRP-USD",  shortName: "XRP",
                  seed: 3005, startPrice: 2.4,   drift: 0.0003, vol: 0.040),
        IndexSpec(symbol: "DOGE-USD", shortName: "Dogecoin",
                  seed: 3006, startPrice: 0.32,  drift: 0.0002, vol: 0.060),
        IndexSpec(symbol: "ADA-USD",  shortName: "Cardano",
                  seed: 3007, startPrice: 0.55,  drift: 0.0002, vol: 0.045),
        IndexSpec(symbol: "AVAX-USD", shortName: "Avalanche",
                  seed: 3008, startPrice: 35,    drift: 0.0003, vol: 0.050),
        IndexSpec(symbol: "LINK-USD", shortName: "Chainlink",
                  seed: 3009, startPrice: 15,    drift: 0.0004, vol: 0.045),
        IndexSpec(symbol: "TRX-USD",  shortName: "TRON",
                  seed: 3010, startPrice: 0.14,  drift: 0.0002, vol: 0.035),
    ]

    /// Eight commodities — metals, energy, gas — via Yahoo's
    /// front-month futures notation (`=F` suffix). Covers the
    /// standard "macro at a glance" set every commodities dashboard
    /// surfaces. `=F` symbols have no `.`, so `LiveDataStore.ySymbol`
    /// passes them through unchanged.
    static let commodities: [IndexSpec] = [
        IndexSpec(symbol: "GC=F", shortName: "Gold",
                  seed: 5001, startPrice: 2400,  drift: 0.0002, vol: 0.011),
        IndexSpec(symbol: "SI=F", shortName: "Silver",
                  seed: 5002, startPrice: 28,    drift: 0.0002, vol: 0.018),
        IndexSpec(symbol: "HG=F", shortName: "Copper",
                  seed: 5003, startPrice: 4.5,   drift: 0.0001, vol: 0.014),
        IndexSpec(symbol: "PL=F", shortName: "Platinum",
                  seed: 5004, startPrice: 970,   drift: 0.0001, vol: 0.013),
        IndexSpec(symbol: "PA=F", shortName: "Palladium",
                  seed: 5005, startPrice: 950,   drift: 0.0000, vol: 0.018),
        IndexSpec(symbol: "CL=F", shortName: "WTI Crude",
                  seed: 5006, startPrice: 78,    drift: 0.0001, vol: 0.020),
        IndexSpec(symbol: "BZ=F", shortName: "Brent Crude",
                  seed: 5007, startPrice: 82,    drift: 0.0001, vol: 0.020),
        IndexSpec(symbol: "NG=F", shortName: "Natural Gas",
                  seed: 5008, startPrice: 2.3,   drift: -0.0001, vol: 0.030),
    ]

    /// Eight major FX pairs — what every retail forex dashboard
    /// surfaces. Yahoo's `=X` suffix is its native FX notation;
    /// `EURUSD=X` returns the spot rate (and intraday history) of
    /// EUR quoted in USD. `=X` symbols have no `.`, so
    /// `LiveDataStore.ySymbol` passes them through unchanged.
    ///
    /// Note: yen / yuan pairs use `USDJPY=X` / `USDCNY=X` (USD as
    /// base) per Yahoo's convention — that's also how Bloomberg and
    /// Google Finance display them, so it stays unsurprising.
    static let forex: [IndexSpec] = [
        IndexSpec(symbol: "EURUSD=X", shortName: "EUR / USD",
                  seed: 7001, startPrice: 1.08,  drift: 0.0001, vol: 0.005),
        IndexSpec(symbol: "GBPUSD=X", shortName: "GBP / USD",
                  seed: 7002, startPrice: 1.27,  drift: 0.0001, vol: 0.006),
        IndexSpec(symbol: "USDJPY=X", shortName: "USD / JPY",
                  seed: 7003, startPrice: 152.0, drift: 0.0001, vol: 0.005),
        IndexSpec(symbol: "USDCNY=X", shortName: "USD / CNY",
                  seed: 7004, startPrice: 7.20,  drift: 0.0000, vol: 0.003),
        IndexSpec(symbol: "AUDUSD=X", shortName: "AUD / USD",
                  seed: 7005, startPrice: 0.66,  drift: 0.0001, vol: 0.006),
        IndexSpec(symbol: "USDCAD=X", shortName: "USD / CAD",
                  seed: 7006, startPrice: 1.36,  drift: 0.0001, vol: 0.005),
        IndexSpec(symbol: "USDCHF=X", shortName: "USD / CHF",
                  seed: 7007, startPrice: 0.88,  drift: 0.0000, vol: 0.005),
        IndexSpec(symbol: "NZDUSD=X", shortName: "NZD / USD",
                  seed: 7008, startPrice: 0.61,  drift: 0.0001, vol: 0.007),
    ]

    /// FRED macro series — the rates / inflation / labor / growth snapshot an
    /// economic dashboard surfaces. Symbols are FRED series IDs (not Yahoo), so
    /// `LiveDataStore` would fail to fetch them; the Macro tab routes these
    /// through `FredDataStore`, with each spec's `fredUnits` choosing the right
    /// transform (YoY % for inflation/growth, monthly change for payrolls).
    /// Real values land once FRED is wired via `AgentSettings.fredKey`;
    /// otherwise the synthetic GBM fallback renders (footer surfaces the caveat).
    ///
    /// Grouped: rates & curve, inflation, labor, growth & activity.
    static let macroIndicators: [IndexSpec] = [
        // ── Rates & curve ──
        IndexSpec(symbol: "DGS10",    shortName: "10Y Yield (%)",
                  seed: 6001, startPrice: 4.30, drift: 0.0001, vol: 0.005),
        IndexSpec(symbol: "DGS2",     shortName: "2Y Yield (%)",
                  seed: 6002, startPrice: 4.10, drift: 0.0001, vol: 0.005),
        IndexSpec(symbol: "FEDFUNDS", shortName: "Fed Funds (%)",
                  seed: 6003, startPrice: 5.25, drift: -0.0001, vol: 0.002),
        IndexSpec(symbol: "T10Y2Y",   shortName: "10Y-2Y Spread (%)",
                  seed: 6004, startPrice: 0.20, drift: 0.0002, vol: 0.010),
        // ── Inflation (YoY %) ──
        IndexSpec(symbol: "CPIAUCSL", shortName: "CPI YoY (%)",
                  seed: 6006, startPrice: 3.20, drift: -0.0001, vol: 0.004,
                  fredUnits: "pc1"),
        IndexSpec(symbol: "CPILFESL", shortName: "Core CPI YoY (%)",
                  seed: 6007, startPrice: 3.40, drift: -0.0001, vol: 0.003,
                  fredUnits: "pc1"),
        IndexSpec(symbol: "PCEPILFE", shortName: "Core PCE YoY (%)",
                  seed: 6008, startPrice: 2.80, drift: -0.0001, vol: 0.003,
                  fredUnits: "pc1"),
        // ── Labor ──
        IndexSpec(symbol: "UNRATE",   shortName: "Unemployment (%)",
                  seed: 6005, startPrice: 4.00, drift: 0.0001, vol: 0.003),
        IndexSpec(symbol: "PAYEMS",   shortName: "Nonfarm Payrolls (Δk)",
                  seed: 6009, startPrice: 200.0, drift: 0.0, vol: 0.30,
                  fredUnits: "chg"),
        // ICSA is reported in ACTUAL persons (~220,000), not thousands — keep
        // the fallback at that scale so it matches the live value.
        IndexSpec(symbol: "ICSA",     shortName: "Initial Claims",
                  seed: 6010, startPrice: 220_000, drift: 0.0, vol: 0.05),
        // ── Growth & activity ──
        IndexSpec(symbol: "A191RL1Q225SBEA", shortName: "Real GDP (QoQ ann. %)",
                  seed: 6011, startPrice: 2.50, drift: 0.0, vol: 0.10),
        IndexSpec(symbol: "RSAFS",    shortName: "Retail Sales YoY (%)",
                  seed: 6012, startPrice: 3.00, drift: 0.0, vol: 0.05,
                  fredUnits: "pc1"),
    ]

    /// Twelve non-US benchmarks. Sliced into Asia Pacific / Europe /
    /// Americas by the tab selector via `region`. Coverage picked to
    /// give one or two of the most-watched indices per macro region
    /// without flattening the list.
    ///
    /// Note: Shanghai Composite uses Yahoo's `000001.SS` format
    /// (preserved by `LiveDataStore.ySymbol(...)` thanks to the
    /// `.SS` exchange-suffix carve-out).
    static let globalIndices: [IndexSpec] = [
        // Asia Pacific
        IndexSpec(symbol: "^N225",      shortName: "Nikkei 225",
                  region: .asiaPacific,
                  seed: 4001, startPrice: 38500,  drift: 0.0003, vol: 0.010),
        IndexSpec(symbol: "^HSI",       shortName: "Hang Seng",
                  region: .asiaPacific,
                  seed: 4002, startPrice: 18500,  drift: 0.0001, vol: 0.013),
        IndexSpec(symbol: "000001.SS",  shortName: "SSE Composite",
                  region: .asiaPacific,
                  seed: 4003, startPrice: 3100,   drift: 0.0001, vol: 0.010),
        IndexSpec(symbol: "399001.SZ",  shortName: "SZSE Component",
                  region: .asiaPacific,
                  seed: 4007, startPrice: 9500,   drift: 0.0001, vol: 0.012),
        IndexSpec(symbol: "000300.SS",  shortName: "CSI 300",
                  region: .asiaPacific,
                  seed: 4008, startPrice: 3600,   drift: 0.0001, vol: 0.010),
        IndexSpec(symbol: "^HSTECH",    shortName: "HS Tech",
                  region: .asiaPacific,
                  seed: 4009, startPrice: 4200,   drift: 0.0002, vol: 0.018),
        IndexSpec(symbol: "^KS11",      shortName: "KOSPI",
                  region: .asiaPacific,
                  seed: 4004, startPrice: 2750,   drift: 0.0002, vol: 0.011),
        IndexSpec(symbol: "^TWII",      shortName: "Taiwan Weighted",
                  region: .asiaPacific,
                  seed: 4005, startPrice: 20500,  drift: 0.0003, vol: 0.012),
        IndexSpec(symbol: "^BSESN",     shortName: "SENSEX",
                  region: .asiaPacific,
                  seed: 4006, startPrice: 74000,  drift: 0.0004, vol: 0.010),

        // Europe
        IndexSpec(symbol: "^FTSE",      shortName: "FTSE 100",
                  region: .europe,
                  seed: 4101, startPrice: 8200,   drift: 0.0002, vol: 0.008),
        IndexSpec(symbol: "^GDAXI",     shortName: "DAX",
                  region: .europe,
                  seed: 4102, startPrice: 18300,  drift: 0.0003, vol: 0.010),
        IndexSpec(symbol: "^FCHI",      shortName: "CAC 40",
                  region: .europe,
                  seed: 4103, startPrice: 8000,   drift: 0.0002, vol: 0.009),
        IndexSpec(symbol: "^STOXX50E",  shortName: "Euro Stoxx 50",
                  region: .europe,
                  seed: 4104, startPrice: 4950,   drift: 0.0002, vol: 0.009),

        // Americas
        IndexSpec(symbol: "^BVSP",      shortName: "Bovespa",
                  region: .americas,
                  seed: 4201, startPrice: 128000, drift: 0.0001, vol: 0.013),
        IndexSpec(symbol: "^GSPTSE",    shortName: "S&P/TSX",
                  region: .americas,
                  seed: 4202, startPrice: 22000,  drift: 0.0002, vol: 0.008),
    ]
}

// MARK: - Earnings calendar

/// One upcoming-earnings entry. Static fixture for now — when the
/// Finnhub `/calendar/earnings` integration lands, real entries
/// land in the same shape so the row layout stays unchanged.
struct EarningsEntry: Identifiable, Hashable {
    enum Timing: String, Hashable {
        case bmo  = "BMO"      // Before market open
        case dmh  = "DMH"      // During market hours (rare for mega-caps)
        case amc  = "AMC"      // After market close
    }
    let symbol: String
    let name: String
    let day: Int               // day of month
    let monthLabel: String     // localised "MAY" etc
    let epsEstimate: Double
    let timing: Timing
    var id: String { "\(symbol)-\(monthLabel)-\(day)" }
}

extension MarketSpec {
    /// Synthetic next-10-days earnings calendar. Tickers chosen from
    /// the mega-cap pool so the names are recognisable; dates anchored
    /// to a real near-future window. Replace with live Finnhub data
    /// once `EarningsCalendarProvider` lands.
    static let upcomingEarnings: [EarningsEntry] = [
        EarningsEntry(symbol: "NVDA",  name: "NVIDIA Corporation",
                      day: 26, monthLabel: "MAY",
                      epsEstimate: 4.21, timing: .amc),
        EarningsEntry(symbol: "CRM",   name: "Salesforce, Inc.",
                      day: 27, monthLabel: "MAY",
                      epsEstimate: 2.83, timing: .amc),
        EarningsEntry(symbol: "COST",  name: "Costco Wholesale",
                      day: 29, monthLabel: "MAY",
                      epsEstimate: 4.55, timing: .amc),
        EarningsEntry(symbol: "DELL",  name: "Dell Technologies",
                      day: 30, monthLabel: "MAY",
                      epsEstimate: 1.71, timing: .amc),
        EarningsEntry(symbol: "ZM",    name: "Zoom Communications",
                      day: 30, monthLabel: "MAY",
                      epsEstimate: 1.17, timing: .amc),
        EarningsEntry(symbol: "CRWD",  name: "CrowdStrike Holdings",
                      day: 2,  monthLabel: "JUN",
                      epsEstimate: 1.04, timing: .amc),
        EarningsEntry(symbol: "HPE",   name: "Hewlett Packard Enterprise",
                      day: 3,  monthLabel: "JUN",
                      epsEstimate: 0.42, timing: .amc),
        EarningsEntry(symbol: "LULU",  name: "Lululemon Athletica",
                      day: 4,  monthLabel: "JUN",
                      epsEstimate: 2.65, timing: .amc),
    ]
}

// MARK: - Snapshot helper

/// Reduces a CandleSeries to the four numbers an index card needs
/// (last, day-over-day change, change %, the closes for the sparkline).
fileprivate struct IndexSnapshot {
    let last: Double
    let change: Double
    let changePct: Double
    let closes: [Double]

    init(series: CandleSeries) {
        let candles = series.candles
        guard let lastCandle = candles.last else {
            self.last = 0; self.change = 0; self.changePct = 0; self.closes = []
            return
        }
        let last = lastCandle.close
        let prev = candles.count >= 2 ? candles[candles.count - 2].close : last
        let change = last - prev
        self.last = last
        self.change = change
        self.changePct = prev == 0 ? 0 : (change / prev) * 100
        // Last ~30 closes for the sparkline. More than that and the
        // mini-chart loses resolution at this card width.
        self.closes = Array(candles.suffix(30).map(\.close))
    }

    var isUp: Bool { change >= 0 }

    var changeString: String {
        (isUp ? "+" : "") + String(format: "%.2f", change)
    }

    var changePctString: String {
        let sign = isUp ? "+" : ""
        return "(\(sign)\(String(format: "%.2f", changePct))%)"
    }
}
