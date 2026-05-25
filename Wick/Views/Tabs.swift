import SwiftUI
import CoreCharts
import IndicatorKit
import TradingFloor

// MARK: - Overview tab (Apple Stocks-style)

/// Inline area chart + volume profile + stats grid + news grid, all
/// without card backdrops. Range picker is flat text (Apple style).
struct OverviewTab: View {
    let ticker: Ticker
    @Binding var range: OverviewRange
    let holdings: HoldingsStore

    @Environment(LiveDataStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    /// Per-tab coordinator. Configured up-front with a single main pane
    /// (no volume — Overview renders its own decorative volume strip
    /// separately) and a sparse y-axis (3 target ticks → ~4 nice
    /// numbers, vs the default 6 → ~9 that crowded the right gutter).
    @State private var coordinator = ChartCoordinator(panes: [
        PaneSpec(id: .main, heightWeight: 1, preferredYTickCount: 3)
    ])

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            FlatPicker(items: OverviewRange.allCases, selection: $range,
                       font: .system(size: 13, weight: .medium, design: .rounded))

            previewChart
            volumeProfile
            statsGrid
            seeMoreLink
            newsGrid
        }
        // Coordinator was made external (so we can attach `.crosshairHover`)
        // — that means CandleChartView won't auto-attach on series change.
        // We push the trimmed series in here on range / source updates so
        // the chart always reflects the picker.
        .onAppear { attachOverviewSeries() }
        .onChange(of: range) { _, _ in attachOverviewSeries() }
        .onChange(of: store.source(for: ticker.symbol,
                                    interval: range.underlyingInterval)) { _, _ in
            attachOverviewSeries()
        }
        .onChange(of: holdings.holdings) { _, _ in pushMarkers() }
    }

    private func attachOverviewSeries() {
        let s = ticker.overviewSeries(range, store: store)
        coordinator.attach(s, lastBarsToShow: s.candles.count)
        pushMarkers()
    }

    /// Snap each user-entered Buy/Sell transaction for this ticker to the
    /// closest candle in the trimmed Overview series and hand the result
    /// to the coordinator as `MarkerEvent`s. `MarkerRenderer` looks up
    /// markers by *exact* `time` match, so we use the candle's own time
    /// instead of the user-entered date. Transactions whose date falls
    /// outside the trimmed window get dropped — otherwise "closest"
    /// would jam a 2024 marker onto the leftmost 2026 bar.
    private func pushMarkers() {
        guard let series = coordinator.series, !series.candles.isEmpty else {
            coordinator.markers = []
            return
        }
        let txs = holdings.transactions(for: ticker.symbol)
        guard !txs.isEmpty else {
            coordinator.markers = []
            return
        }
        let candles = series.candles
        let times = candles.map(\.time)
        let first = times.first!
        let last = times.last!
        let tolerance = max(60, series.interval.approximateSeconds / 2)
        let lower = first.addingTimeInterval(-tolerance)
        let upper = last.addingTimeInterval(tolerance)
        let theme = appleTheme(for: colorScheme)
        let buyColor = theme.candleDownStroke      // red
        let sellColor = theme.lineStroke           // blue (area-chart accent)
        var markers: [MarkerEvent] = txs.compactMap { tx in
            guard tx.date >= lower, tx.date <= upper else { return nil }
            let snapped = Self.closestCandleTime(to: tx.date, in: times)
            // Anchor at the user's fill price so the dot lines up with
            // the callout's notch/connector that uses the same y. Without
            // this the dot floats at candle.close while the callout
            // points to tx.price — they drift apart by cents.
            return MarkerEvent(
                time: snapped,
                kind: .news,
                label: nil,
                position: .atPrice,
                color: tx.side == .buy ? buyColor : sellColor,
                price: tx.price)
        }
        // Ant-Fund-style "Buy" / "Sell" callout pills for the FIRST buy
        // and the MOST RECENT sell across the whole history (filtered by
        // visible window so we don't draw a 2024 callout on the 1M view).
        // Anchored at the user's fill price (m.price) so MarkerRenderer
        // can draw a connector line down/up to the actual data point.
        let sorted = txs.sorted { $0.date < $1.date }
        if let firstBuy = sorted.first(where: { $0.side == .buy }),
           firstBuy.date >= lower, firstBuy.date <= upper {
            markers.append(MarkerEvent(
                time: Self.closestCandleTime(to: firstBuy.date, in: times),
                kind: .custom,
                label: "Buy",
                position: .aboveBar,
                color: buyColor,
                price: firstBuy.price))
        }
        if let lastSell = sorted.reversed().first(where: { $0.side == .sell }),
           lastSell.date >= lower, lastSell.date <= upper {
            markers.append(MarkerEvent(
                time: Self.closestCandleTime(to: lastSell.date, in: times),
                kind: .custom,
                label: "Sell",
                position: .belowBar,
                color: sellColor,
                price: lastSell.price))
        }
        coordinator.markers = markers
    }

    private static func closestCandleTime(to date: Date,
                                          in times: [Date]) -> Date
    {
        var best = times[0]
        var bestDelta = abs(times[0].timeIntervalSince(date))
        for t in times.dropFirst() {
            let d = abs(t.timeIntervalSince(date))
            if d < bestDelta { bestDelta = d; best = t }
        }
        return best
    }

    // MARK: Chart

    private var previewChart: some View {
        let trimmed = ticker.overviewSeries(range, store: store)

        return CandleChartView(series: trimmed,
                               style: .area,
                               showVolume: false,
                               allowGestures: false,
                               showLastPriceTag: true,
                               baselinePrice: nil,
                               coordinator: coordinator)
            .chartTheme(appleTheme(for: colorScheme))
            .frame(height: 240)
            // Custom hover: the price tag follows the BAR's close at the
            // cursor's x — not the cursor's y (which is what the library's
            // generic .crosshairHover does). Better fit for an area
            // chart where users want "what's the price on that day".
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                    let idx = coordinator.timeScale.index(forX: pt.x)
                    guard let s = coordinator.series,
                          idx >= 0, idx < s.candles.count
                    else {
                        coordinator.cursorBarIndex = nil
                        coordinator.cursorPanePrice = nil
                        return
                    }
                    coordinator.cursorBarIndex = idx
                    coordinator.cursorPane = .main
                    coordinator.cursorPanePrice = s.candles[idx].close
                case .ended:
                    coordinator.cursorBarIndex = nil
                    coordinator.cursorPanePrice = nil
                }
            }
    }

    /// Thin row of volume marks under the chart — Apple Stocks' decorative
    /// volume profile. Each bar is a vertical Capsule, height is plain
    /// `v / maxV` (no compression). Raw candle counts vary wildly across
    /// ranges (65 on 1W up to 520 on 10Y); the strip stays *roughly*
    /// the same density by bucket-aggregating only when the raw count
    /// exceeds `volumeBarSoftCap`. Short ranges pass through one-to-one.
    private var volumeProfile: some View {
        let trimmed = ticker.overviewSeries(range, store: store)
        let buckets = Self.volumeBuckets(from: trimmed.candles,
                                          softCap: Self.volumeBarSoftCap)
        let theme = appleTheme(for: colorScheme)
        return Canvas { ctx, size in
            guard let maxV = buckets.map(\.volume).max(), maxV > 0 else { return }
            // CandleChartView reserves a 48 pt right-side gutter for the
            // price axis + last-price pill — its candles / area path stop
            // at `size.width - 48`. The volume strip is a sibling Canvas,
            // so it has to apply the same inset by hand to line its
            // right edge up with the trend above.
            let rightGutter: CGFloat = 48
            let plotWidth = max(1, size.width - rightGutter)
            let spacing = plotWidth / CGFloat(max(buckets.count, 1))
            let pillWidth = max(2, min(5, spacing * 0.55))
            for (i, b) in buckets.enumerated() {
                let h = CGFloat(b.volume / maxV) * size.height
                let x = (CGFloat(i) + 0.5) * spacing
                let rect = CGRect(x: x - pillWidth / 2,
                                  y: size.height - h,
                                  width: pillWidth,
                                  height: max(pillWidth, h))
                let pill = Path(roundedRect: rect,
                                cornerRadius: pillWidth / 2)
                ctx.fill(pill, with: .color(theme.axisLabel.opacity(0.45)))
            }
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }

    /// Soft cap on the volume strip's bar count. Doubled from the
    /// previous 100 (which felt too sparse against the dense waveform
    /// above). Aggregation is O(n) and trivial, so the higher cap costs
    /// nothing. New per-range counts (sum-based bucketing — see below):
    ///   1D 78 · 1W 65 · 1M 154 · 3M 66 · 6M 132 ·
    ///   1Y ~126 · 2Y ~168 · 5Y ~130 · 10Y ~174
    /// — about a 2.7× spread across the picker.
    private static let volumeBarSoftCap: Int = 200

    /// One aggregated volume bar. `isUp` is decided by the bucket's last
    /// close vs its first open (treats the whole bucket as a single
    /// pseudo-candle), so the up / down tint reflects net direction over
    /// the bucket window.
    private struct VolumeBucket {
        let volume: Double
        let isUp: Bool
    }

    /// Bucket `candles` so the returned count stays at or below `softCap`.
    /// Short streams pass through one-to-one. Long streams sum the
    /// volumes within each group — "total volume over the bucket
    /// window", which is the natural semantic for a volume strip. With
    /// the higher `softCap` (200) groups stay small (≤ 3 candles each)
    /// so a spike day still dominates its bucket even after summing.
    private static func volumeBuckets(from candles: ContiguousArray<Candle>,
                                       softCap: Int) -> [VolumeBucket]
    {
        let n = candles.count
        guard n > 0, softCap > 0 else { return [] }
        if n <= softCap {
            return candles.map {
                VolumeBucket(volume: $0.volume, isUp: $0.close >= $0.open)
            }
        }
        let groupSize = Int((Double(n) / Double(softCap)).rounded(.up))
        var out: [VolumeBucket] = []
        out.reserveCapacity(n / groupSize + 1)
        var i = 0
        while i < n {
            let end = min(i + groupSize, n)
            var sum = 0.0
            for k in i..<end { sum += candles[k].volume }
            let isUp = candles[end - 1].close >= candles[i].open
            out.append(VolumeBucket(volume: sum, isUp: isUp))
            i = end
        }
        return out
    }

    // MARK: Stats grid

    private var statsGrid: some View {
        let stats = StatsBuilder.flatRows(series: ticker.overviewSeries(range, store: store),
                                           dailySeries: ticker.liveSeries(.d1, store: store))
        return LazyVGrid(columns: Array(repeating:
                            GridItem(.flexible(), alignment: .leading), count: 4),
                         alignment: .leading,
                         spacing: 14) {
            ForEach(stats, id: \.label) { cell in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(cell.label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    Text(cell.value)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    // MARK: "See More" + News

    private var seeMoreLink: some View {
        Button(action: {}) {
            HStack(spacing: 3) {
                Text("See More Data from Yahoo Finance")
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 14))
            .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
    }

    private var newsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                            GridItem(.flexible(), alignment: .topLeading)],
                  alignment: .leading,
                  spacing: 20) {
            ForEach(NewsFixtures.items(for: ticker.symbol)) { item in
                NewsRow(item: item, expanded: true)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - Chart tab (Apple Stocks-influenced, with technicals)

/// K-line + volume + SMAs + MACD/KDJ/RSI sub-panes. Picker is now flat
/// (matches Overview); the chart is inline (no surrounding glass card).
struct ChartTab: View {
    let ticker: Ticker
    @Binding var scale: ChartScale
    @Binding var scale2: ChartScale
    @Binding var splitView: Bool
    let coordinator: ChartCoordinator
    let coordinator2: ChartCoordinator
    let engine: IndicatorEngine
    let engine2: IndicatorEngine
    /// Reference-typed; held here so the SwiftUI tracking pulls in
    /// changes when the indicator manager sheet (or any other consumer)
    /// edits the list. Sync happens in DetailView's onChange handler.
    let indicators: ChartIndicatorConfig
    /// User's buy/sell transactions; ChartTabState pushes a yellow
    /// triangle per transaction (apex at fill price) onto each
    /// coordinator's `markers` list.
    let holdings: HoldingsStore

    @Environment(LiveDataStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if splitView {
                HStack(spacing: 16) {
                    chartPane(scale: $scale, coord: coordinator, engine: engine)
                    chartPane(scale: $scale2, coord: coordinator2, engine: engine2)
                }
            } else {
                chartPane(scale: $scale, coord: coordinator, engine: engine)
            }
        }
    }

    /// One chart pane: scale picker → K-line + indicators → scrubber.
    private func chartPane(scale: Binding<ChartScale>,
                           coord: ChartCoordinator,
                           engine: IndicatorEngine) -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            FlatPicker(items: ChartScale.allCases, selection: scale,
                       font: .system(size: 12, weight: .semibold, design: .rounded),
                       layout: .compact)
            chartBlock(scale: scale.wrappedValue, coord: coord, engine: engine)
            RangeScrubberView(coordinator: coord, height: 32)
        }
    }

    private func chartBlock(scale: ChartScale,
                            coord: ChartCoordinator,
                            engine: IndicatorEngine) -> some View
    {
        let series = ticker.liveSeries(scale.underlyingInterval, store: store)
        let theme = appleTheme(for: colorScheme)
        return ZStack(alignment: .topLeading) {
            CandleChartView(series: series,
                            style: .candle,
                            showVolume: true,
                            allowGestures: true,
                            showLastPriceTag: true,
                            coordinator: coord)
            IndicatorOverlay(coordinator: coord, engine: engine)
            mainPaneCaption(theme: theme)
                .padding(.leading, 8)
                .padding(.top, 4)
        }
        .chartTheme(theme)
        .frame(minHeight: 520)
        .crosshairHover(coordinator: coord)
    }

    /// "K · SMA(5/10/20)" with the three periods colored to match the
    /// SMA line tints. macOS 26 deprecated `Text + Text`; using
    /// `AttributedString` instead preserves the single-line layout and
    /// per-run colours.
    private func mainPaneCaption(theme: ChartTheme) -> some View {
        let dim = theme.axisLabel.opacity(0.85)
        let sep = theme.axisLabel.opacity(0.55)
        var s = AttributedString("K · SMA(")
        s.foregroundColor = dim
        var five = AttributedString("5")
        five.foregroundColor = theme.indicatorColor(0)
        var slash1 = AttributedString("/")
        slash1.foregroundColor = sep
        var ten = AttributedString("10")
        ten.foregroundColor = theme.indicatorColor(1)
        var slash2 = AttributedString("/")
        slash2.foregroundColor = sep
        var twenty = AttributedString("20")
        twenty.foregroundColor = theme.indicatorColor(2)
        var close = AttributedString(")")
        close.foregroundColor = dim
        s += five + slash1 + ten + slash2 + twenty + close
        return Text(s)
            .font(theme.axisLabelFont)
            .allowsHitTesting(false)
    }
}

// MARK: - News tab

struct NewsTab: View {
    let ticker: Ticker

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                            GridItem(.flexible(), alignment: .topLeading)],
                  alignment: .leading,
                  spacing: 20) {
            ForEach(NewsFixtures.items(for: ticker.symbol)) { item in
                NewsRow(item: item, expanded: true)
            }
        }
    }
}

/// One news entry — paper-flat. Apple Stocks uses plain typography +
/// a thin separator line under each item, no card chrome. Glass /
/// rounded-rect cards read as too heavy in a dense news column. The
/// rule: surfaces are for actionable groups; news is content, not UI.
struct NewsRow: View {
    let item: NewsItem
    var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.source)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(item.headline)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(expanded ? nil : 2)
            if expanded {
                Text(item.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text(item.ageLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - AI tab

/// History-first surface for the multi-agent desk. The user lands on
/// previously generated reports for this ticker (read off the shared
/// `ReportHistoryStore`, persisted to disk); running a fresh analysis is
/// always available as the primary action top-right, but no longer the
/// gate that hides existing work.
/// **Passive history** view for one ticker's accumulated workflow
/// reports. No "Run analysis" button, no run-in-progress chrome,
/// no settings disclosure — all of that has moved to Wicker (ask
/// Wicker for an analysis, the agent will kick off the workflow
/// on the user's behalf). The AI tab is purely a chronological
/// archive: click a report to expand it inline.
///
/// The same `ReportHistoryStore` that the Wicker-triggered workflow
/// writes into feeds this view, so new analyses appear at the top
/// of the list automatically the next time the user opens the tab.
struct AITab: View {
    let ticker: Ticker
    let range: OverviewRange
    @Environment(ReportHistoryStore.self) private var history
    /// Which historical report's full transcript is expanded inline.
    /// `nil` = list-only view. Keyed by `generatedAt` since `Report`
    /// has no id and timestamps are unique per (ticker, run).
    @State private var expanded: Date?

    private var historyForTicker: [Report] {
        history.reports(for: ticker.symbol)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            historyOrEmptyState
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text("AI Desk").font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("Ask Wicker to run a new analysis")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - History list (or empty state)

    @ViewBuilder
    private var historyOrEmptyState: some View {
        let items = historyForTicker
        if items.isEmpty {
            emptyState
        } else {
            historyList(items)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No analyses yet for \(ticker.symbol).")
                .font(.system(size: 13, weight: .medium))
            Text("Ask Wicker — \"run a full analysis on \(ticker.symbol)\" — "
                 + "and the multi-agent desk (fundamental / technical / "
                 + "sentiment / news → bull-bear debate → trade → risk) will "
                 + "kick off. Completed reports get archived here for "
                 + "side-by-side comparison.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private func historyList(_ items: [Report]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("HISTORY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            // GlassEffectContainer batches the per-row glass surfaces
            // into a single compositor pass and primes any future
            // morph when a row expands / collapses.
            GlassEffectContainer(spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items, id: \.generatedAt) { report in
                        historyRow(report)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ report: Report) -> some View {
        let isOpen = (expanded == report.generatedAt)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded = isOpen ? nil : report.generatedAt
            } label: {
                historyRowHeader(report, isOpen: isOpen)
            }
            .buttonStyle(.plain)

            if isOpen {
                reportView(report)
                    .padding(.top, 12)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 14,
                     tint: ratingColor(report.rating).opacity(isOpen ? 0.10 : 0))
    }

    private func historyRowHeader(_ report: Report, isOpen: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(report.rating.label.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(ratingColor(report.rating).gradient, in: Capsule())
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 2) {
                Text(report.summary.split(whereSeparator: \.isNewline)
                        .first.map(String.init) ?? report.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(isOpen ? nil : 2)
                    .multilineTextAlignment(.leading)
                Text(report.generatedAt.formatted(
                    date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Report view (per-history-row body)

    private func reportView(_ report: Report) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            verdictCard(report)

            // Trader's bottom line.
            Text(report.summary)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .liquidGlass(cornerRadius: 14)

            Text("THE DESK")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)

            ForEach(report.transcript) { agentCard($0) }

            Text(report.disclaimer)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    // MARK: Verdict header + rating gauge

    private func verdictCard(_ report: Report) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(report.ticker).font(.system(size: 22, weight: .bold))
                    Text(report.asOf.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(report.rating.label.uppercased())
                    .font(.system(size: 14, weight: .heavy))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(ratingColor(report.rating).gradient, in: Capsule())
                    .foregroundStyle(.white)
            }
            ratingGauge(report.rating)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 16, tint: ratingColor(report.rating).opacity(0.16))
    }

    private func ratingGauge(_ rating: Rating) -> some View {
        let labels = ["Strong\nSell", "Sell", "Hold", "Buy", "Strong\nBuy"]
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Rating.allCases, id: \.self) { r in
                let active = r == rating
                VStack(spacing: 5) {
                    Capsule()
                        .fill(active ? ratingColor(r).gradient
                                     : Color.secondary.opacity(0.18).gradient)
                        .frame(height: active ? 10 : 6)
                    Text(labels[r.rawValue])
                        .font(.system(size: 8, weight: active ? .bold : .regular))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(active ? ratingColor(r) : Color.secondary)
                }
            }
        }
    }

    // MARK: Agent cards

    private func agentCard(_ msg: AgentMessage) -> some View {
        let style = roleStyle(msg.role)
        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: style.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style.color)
                .frame(width: 26, height: 26)
                .background(style.color.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(msg.role).font(.system(size: 12.5, weight: .semibold))
                Text(msg.content)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 12)
    }

    /// SF Symbol + accent per desk role.
    private func roleStyle(_ role: String) -> (symbol: String, color: Color) {
        switch role {
        case "Fundamental Analyst": return ("building.columns", .teal)
        case "Technical Analyst":   return ("chart.xyaxis.line", .blue)
        case "Sentiment Analyst":   return ("bubble.left.and.bubble.right", .purple)
        case "News Analyst":        return ("newspaper", .indigo)
        case "Bull Researcher":     return ("arrow.up.forward.circle", .green)
        case "Bear Researcher":     return ("arrow.down.forward.circle", .red)
        case "Trader":              return ("checkmark.seal", .orange)
        case "Risk Manager":        return ("shield.lefthalf.filled", Color.secondary)
        default:                    return ("sparkles", Color.secondary)
        }
    }

    private func ratingColor(_ rating: Rating) -> Color {
        switch rating {
        case .strongSell: return .red
        case .sell:       return .orange
        case .hold:       return .gray
        case .buy:        return .green
        case .strongBuy:  return .green
        }
    }
}

// MARK: - Stats builder

enum StatsBuilder {
    struct Cell { let label: String; let value: String }

    /// Flat 12-cell list (Open / High / Low / Vol / P/E / Mkt Cap / 52W H /
    /// 52W L / Avg Vol / Yield / Beta / EPS) — matches Apple Stocks order
    /// when laid out in a 4-column grid.
    @MainActor
    static func flatRows(series: CandleSeries, dailySeries: CandleSeries) -> [Cell] {
        let c = series.candles
        guard let last = c.last else { return [] }
        let high = c.map(\.high).max()  ?? last.close
        let low  = c.map(\.low).min()   ?? last.close
        let vol  = c.last?.volume ?? 0
        let avgV = c.map(\.volume).reduce(0, +) / Double(max(1, c.count))
        let yearSlice = dailySeries.candles.suffix(252)
        let high52 = yearSlice.map(\.high).max() ?? last.close
        let low52  = yearSlice.map(\.low).min()  ?? last.close

        return [
            Cell(label: "Open",    value: fmt(last.open)),
            Cell(label: "Vol",     value: fmtCompact(vol)),
            Cell(label: "52W H",   value: fmt(high52)),
            Cell(label: "Yield",   value: "—"),
            Cell(label: "High",    value: fmt(high)),
            Cell(label: "P/E",     value: "—"),
            Cell(label: "52W L",   value: fmt(low52)),
            Cell(label: "Beta",    value: "1.06"),
            Cell(label: "Low",     value: fmt(low)),
            Cell(label: "Mkt Cap", value: "—"),
            Cell(label: "Avg Vol", value: fmtCompact(avgV)),
            Cell(label: "EPS",     value: "—"),
        ]
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func fmtCompact(_ v: Double) -> String {
        switch abs(v) {
        case 1e9...: return String(format: "%.1fB", v / 1e9)
        case 1e6...: return String(format: "%.1fM", v / 1e6)
        case 1e3...: return String(format: "%.1fK", v / 1e3)
        default:     return String(format: "%.0f", v)
        }
    }
}

// MARK: - Chart tab setup (panes + indicators)

@MainActor
enum ChartTabState {

    /// First-time wire-up for a coordinator+engine pair against a ticker.
    static func configure(coordinator: ChartCoordinator,
                          engine: IndicatorEngine,
                          ticker: Ticker,
                          scale: ChartScale,
                          store: LiveDataStore,
                          indicators: ChartIndicatorConfig,
                          holdings: HoldingsStore? = nil)
    {
        syncIndicators(coordinator: coordinator, config: indicators)
        IndicatorPaneAutoscaler.install(coordinator: coordinator, engine: engine)
        apply(coordinator: coordinator, engine: engine,
              ticker: ticker, scale: scale, store: store,
              holdings: holdings)
    }

    /// Mirror the global `ChartIndicatorConfig` onto a coordinator's
    /// `indicators` and `panes`. Called from `configure` and whenever the
    /// user edits the indicator list in the manager sheet — keep both in
    /// lockstep so the autoscaler / overlay / pane chrome all agree.
    static func syncIndicators(coordinator: ChartCoordinator,
                               config: ChartIndicatorConfig)
    {
        coordinator.indicators = config.instances
        coordinator.panes = config.derivedPanes
    }

    /// React to a scale change: attach the series at the underlying bar
    /// interval and pin the viewport to the coordinator's current bar
    /// density (pt/bar) — preserved across 1H / 1D / 1W / 1M / All so the
    /// user's pinch / Cmd-scroll zoom carries through the scale picker.
    /// Falls back to the coordinator's init density (8) on the very first
    /// call before any user zoom.
    static func apply(coordinator: ChartCoordinator,
                      engine: IndicatorEngine,
                      ticker: Ticker,
                      scale: ChartScale,
                      store: LiveDataStore,
                      holdings: HoldingsStore? = nil)
    {
        let bi = scale.underlyingInterval
        let series = ticker.liveSeries(bi, store: store)
        engine.invalidateAll()
        coordinator.attach(series, barSpacing: coordinator.timeScale.barSpacing)
        if let holdings {
            syncTransactionMarkers(coordinator: coordinator,
                                    symbol: ticker.symbol,
                                    holdings: holdings)
        }
    }

    /// Push the user's transactions for `symbol` as yellow apex-anchored
    /// triangles onto the coordinator's `markers` list. Up-triangle for
    /// buys (top vertex on fill price), down-triangle for sells (bottom
    /// vertex on fill price). Transactions whose date falls outside the
    /// series time range are dropped; the rest snap to the closest bar
    /// by time so `MarkerRenderer`'s exact-time lookup finds them.
    static func syncTransactionMarkers(coordinator: ChartCoordinator,
                                        symbol: String,
                                        holdings: HoldingsStore)
    {
        guard let series = coordinator.series, !series.candles.isEmpty else {
            coordinator.markers = []
            return
        }
        let txs = holdings.transactions(for: symbol)
        guard !txs.isEmpty else {
            coordinator.markers = []
            return
        }
        let candles = series.candles
        let times = candles.map(\.time)
        let first = times.first!
        let last = times.last!
        let tolerance = max(60, series.interval.approximateSeconds / 2)
        let lower = first.addingTimeInterval(-tolerance)
        let upper = last.addingTimeInterval(tolerance)
        coordinator.markers = txs.compactMap { tx in
            guard tx.date >= lower, tx.date <= upper else { return nil }
            let snapped = Self.closestTime(to: tx.date, in: times)
            return MarkerEvent(
                time: snapped,
                kind: tx.side == .buy ? .buy : .sell,
                label: nil,
                position: nil,
                color: Color.yellow,
                price: tx.price)
        }
    }

    private static func closestTime(to date: Date, in times: [Date]) -> Date {
        var best = times[0]
        var bestDelta = abs(times[0].timeIntervalSince(date))
        for t in times.dropFirst() {
            let d = abs(t.timeIntervalSince(date))
            if d < bestDelta { bestDelta = d; best = t }
        }
        return best
    }

}
