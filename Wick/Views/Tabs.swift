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
    @Environment(AgentSettings.self) private var settings
    @State private var runner = DeskRunner()
    /// Which historical report's full transcript is expanded inline.
    /// `nil` = list-only view. Keyed by `generatedAt` since `Report`
    /// has no id and timestamps are unique per (ticker, run).
    @State private var expanded: Date?
    /// Selected DAG node inside the expanded report. The
    /// `reportView` clears this when `expanded` changes so each
    /// report opens fresh on its first contributor.
    @State private var selectedAgent: String?
    /// History timeline visibility. Hidden by default — the most
    /// recent report renders inline; clicking the History icon next
    /// to "AI Desk" pops the alternating-vertical timeline above the
    /// report so the user can pick an older entry.
    @State private var historyOpen: Bool = false

    private var historyForTicker: [Report] {
        history.reports(for: ticker.symbol)
    }

    var body: some View {
        let items = historyForTicker
        return VStack(alignment: .leading, spacing: 14) {
            header(historyCount: items.count)
            runStatusStrip
            if items.isEmpty {
                emptyState
            } else {
                if historyOpen {
                    historyTimeline(items)
                        .transition(.opacity.combined(
                            with: .move(edge: .top)))
                }
                if let target = activeReport(in: items) {
                    reportView(target)
                        .id(target.generatedAt) // re-mount per report switch
                }
            }
        }
        .onAppear {
            // Bridge runner → history so a completed run lands in the
            // archive automatically (same behaviour as the workflow
            // when triggered from Wicker chat).
            runner.onCompleted = { report in
                history.save(report)
                expanded = report.generatedAt
                historyOpen = false
            }
            // Default-expand the most recent report when entering the
            // tab so the page never opens blank if there's history.
            if expanded == nil, let latest = historyForTicker.first {
                expanded = latest.generatedAt
            }
        }
    }

    /// Active report — explicit `expanded` selection wins; otherwise
    /// default to most recent. Returns nil only when there's nothing
    /// to show (empty history path is upstream).
    private func activeReport(in items: [Report]) -> Report? {
        if let target = expanded,
           let hit = items.first(where: { $0.generatedAt == target }) {
            return hit
        }
        return items.first
    }

    // MARK: - Header

    private func header(historyCount: Int) -> some View {
        let running: Bool = {
            if case .running = runner.phase { return true }
            return false
        }()
        return HStack(spacing: 12) {
            // Apple-Intelligence "AI" mark — the system glyph
            // (available macOS 15.1+); the Intelligence glow halos
            // the icon to signal "this surface is the agent." Glow
            // pulses while a workflow is running, stays subtle when
            // idle so it doesn't feel restless.
            Image(systemName: "apple.intelligence")
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .intelligenceGlow(active: true,
                                  cornerRadius: 14,
                                  intensity: running ? 1.0 : 0.55)
            Text("AI Desk")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            runButton
            if historyCount > 0 {
                historyToggleButton(count: historyCount)
            }
        }
    }

    /// Compact "History" pill — clock icon + count badge. Click
    /// toggles the alternating vertical timeline above the active
    /// report. Active state highlights the pill so the user knows
    /// they're in "browse history" mode.
    private func historyToggleButton(count: Int) -> some View {
        Button {
            withAnimation(.spring(duration: 0.32)) {
                historyOpen.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold,
                                  design: .rounded))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(historyOpen ? Color.accentColor : .secondary)
            .background(
                Capsule()
                    .fill(historyOpen
                          ? Color.accentColor.opacity(0.18)
                          : Color.secondary.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .strokeBorder(historyOpen
                                  ? Color.accentColor.opacity(0.45)
                                  : Color.clear,
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(historyOpen ? "Hide history" : "Show analysis history")
    }

    /// Prominent "Run Analysis" trigger — the user gap from earlier
    /// versions where the only path was "ask Wicker" (which doesn't
    /// actually kick off the multi-agent workflow yet). Disabled
    /// while a run is in flight; label flips to a spinner during
    /// `.running` phase.
    private var runButton: some View {
        let running: Bool = {
            if case .running = runner.phase { return true }
            return false
        }()
        return Button {
            runner.run(ticker: ticker.symbol, settings: settings)
        } label: {
            HStack(spacing: 6) {
                if running {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(running ? "Running…" : "Run Analysis")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .buttonStyle(LiquidGlassButtonStyle(prominent: true))
        .disabled(running)
        .help(running
              ? "Multi-agent workflow in flight"
              : "Kick off the full desk (fundamental / technical / sentiment / news → bull-bear → trade → risk)")
    }

    /// Beneath the header — surfaces what the runner is doing now.
    /// Idle: hidden. Running: stage label. Failed: red row with the
    /// reason. Done: nothing here, the appended report is visible in
    /// the list below.
    @ViewBuilder
    private var runStatusStrip: some View {
        switch runner.phase {
        case .idle, .done:
            EmptyView()
        case .running(let stage):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(stage)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .liquidGlass(cornerRadius: 10)
        case .failed(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer()
                Button("Retry") {
                    runner.run(ticker: ticker.symbol, settings: settings)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .liquidGlass(cornerRadius: 10,
                         tint: Color.orange.opacity(0.18))
        }
    }

    // MARK: - History timeline (vertical, alternating)

    /// Vertical alternating timeline of every saved report for this
    /// ticker. Newest first (matches `ReportHistoryStore.reports`).
    /// Click any entry to swap the report shown below. Visible only
    /// when the History pill in the header is toggled on.
    private func historyTimeline(_ items: [Report]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("RATING HISTORY · \(items.count) RUNS")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.bottom, 14)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.generatedAt) { idx, report in
                    timelineRow(report,
                                 index: idx,
                                 isFirst: idx == 0,
                                 isLast: idx == items.count - 1)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15),
                              lineWidth: 1)
        )
    }

    /// One timeline entry. Alternates side: even index → left chip,
    /// odd index → right chip. The center spine threads through a
    /// dot for each row; the dot for the active selection scales up
    /// and glows in its rating tint.
    private func timelineRow(_ report: Report,
                              index: Int,
                              isFirst: Bool,
                              isLast: Bool) -> some View
    {
        let isLeft = index.isMultiple(of: 2)
        let tint = ratingColor(report.rating)
        let isActive = (expanded == report.generatedAt)
            || (expanded == nil && isFirst)
        return HStack(alignment: .center, spacing: 0) {
            // LEFT side
            if isLeft {
                timelineChip(report, tint: tint,
                             active: isActive, alignRight: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 14)
            } else {
                Color.clear.frame(maxWidth: .infinity)
            }

            // Center spine
            ZStack {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.secondary.opacity(isFirst ? 0 : 0.28))
                        .frame(width: 1.2)
                    Rectangle()
                        .fill(Color.secondary.opacity(isLast ? 0 : 0.28))
                        .frame(width: 1.2)
                }
                Circle()
                    .fill(tint)
                    .frame(width: isActive ? 14 : 10,
                           height: isActive ? 14 : 10)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.3),
                                          lineWidth: 1.2)
                    )
                    .shadow(color: isActive ? tint : .clear,
                            radius: isActive ? 8 : 0)
                    .animation(.spring(duration: 0.3), value: isActive)
            }
            .frame(width: 40)

            // RIGHT side
            if !isLeft {
                timelineChip(report, tint: tint,
                             active: isActive, alignRight: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
            } else {
                Color.clear.frame(maxWidth: .infinity)
            }
        }
        .frame(minHeight: 78)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(duration: 0.32)) {
                expanded = report.generatedAt
                selectedAgent = nil  // re-default to Trader on switch
                historyOpen = false  // collapse timeline after pick
            }
        }
    }

    private func timelineChip(_ report: Report,
                               tint: Color,
                               active: Bool,
                               alignRight: Bool) -> some View
    {
        let summary = report.summary
            .components(separatedBy: "\n")
            .first ?? report.summary
        return VStack(alignment: alignRight ? .trailing : .leading,
                       spacing: 6) {
            HStack(spacing: 8) {
                if alignRight { Spacer(minLength: 0) }
                Text(report.rating.label.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.5)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(tint.gradient, in: Capsule())
                    .foregroundStyle(.white)
                Text(report.generatedAt.formatted(
                        date: .abbreviated, time: .shortened))
                    .font(.system(size: 10, weight: .medium,
                                  design: .monospaced))
                    .foregroundStyle(.secondary)
                if !alignRight { Spacer(minLength: 0) }
            }
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(alignRight ? .trailing : .leading)
                .frame(maxWidth: .infinity,
                       alignment: alignRight ? .trailing : .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active
                      ? tint.opacity(0.14)
                      : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(active
                              ? tint.opacity(0.55)
                              : Color.secondary.opacity(0.18),
                              lineWidth: 1)
        )
        .frame(maxWidth: 360)
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

    // MARK: - Report view (active selection)

    /// Layout for the expanded report:
    ///   - Verdict hero (ticker / rating chip / compact gauge)
    ///   - "Bottom line" editorial paragraph
    ///   - HSplitView: DAG on the left, selected contributor's
    ///     markdown on the right (the side-by-side reading layout
    ///     the user asked for — chart + content, not stacked)
    ///   - Disclaimer footer
    private func reportView(_ report: Report) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            verdictCard(report)
            bottomLine(report)
            deskSection(report)
            disclaimerRow(report)
        }
        .onAppear {
            // Default-select the report's verdict producer (Trader)
            // so the right pane has content the moment the row opens.
            if selectedAgent == nil {
                selectedAgent = DeskDAGView.nodeId(for: "Trader")
                    ?? DeskDAGView.nodes.first?.id
            }
        }
    }

    // MARK: Verdict header + rating gauge

    /// Hero card. Cleaner type stack (ticker huge, "As of <date>"
    /// subdued, big rating chip on the right). Gauge sits in its own
    /// row below for breathing room.
    private func verdictCard(_ report: Report) -> some View {
        let tint = ratingColor(report.rating)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.ticker)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("As of " + report.asOf.formatted(
                            date: .abbreviated, time: .omitted))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(report.rating.label.uppercased())
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(1.0)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(tint.gradient, in: Capsule())
                    .foregroundStyle(.white)
            }
            ratingGauge(report.rating)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 16, tint: tint.opacity(0.12))
    }

    /// Editorial "bottom line" — Stocks app uses a paragraph with a
    /// thin coloured leading rule to set off the human-readable take.
    /// No glass card around the text itself; it's content.
    private func bottomLine(_ report: Report) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(ratingColor(report.rating).opacity(0.85))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text("THE BOTTOM LINE")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.0)
                    .foregroundStyle(.tertiary)
                Text(report.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Side-by-side desk view: workflow DAG on the left, selected
    /// contributor's full markdown reasoning on the right. Replaces
    /// the earlier stacked phase list — the DAG carries the structure
    /// visually, and the reading pane is no longer a wall of text.
    private func deskSection(_ report: Report) -> some View {
        let messagesByNodeID: [String: AgentMessage] = Dictionary(
            uniqueKeysWithValues: report.transcript.compactMap { msg in
                guard let id = DeskDAGView.nodeId(for: msg.role) else {
                    return nil
                }
                return (id, msg)
            })

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("THE DESK")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.0)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(report.transcript.count) contributors · click any node")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .top, spacing: 22) {
                // LEFT: DAG flow chart
                DeskDAGView(selected: Binding(
                    get: { selectedAgent },
                    set: { newValue in
                        // Always keep one node selected so the right
                        // pane never goes blank inside an open report.
                        if let newValue { selectedAgent = newValue }
                    }
                ))
                .frame(width: 460, height: 520)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial.opacity(0.4))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18),
                                       lineWidth: 1)
                )

                // RIGHT: selected analyst's markdown
                analystReadingPane(
                    activeID: selectedAgent,
                    messagesByNodeID: messagesByNodeID
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Right-side reading column. Renders the active DAG node's
    /// markdown content via `WickMarkdown`, with a small header row
    /// (avatar + name + phase pill) anchoring identity at the top.
    @ViewBuilder
    private func analystReadingPane(
        activeID: String?,
        messagesByNodeID: [String: AgentMessage]
    ) -> some View {
        if let id = activeID,
           let node = DeskDAGView.nodes.first(where: { $0.id == id }),
           let msg = messagesByNodeID[id]
        {
            let phase = AgentPhase.from(role: msg.role)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    DeskNodeAvatar(node: node, isSelected: false)
                        .frame(width: 90, height: 90)
                        .scaleEffect(0.7, anchor: .topLeading)
                        .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(msg.role)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("\(phase.title.uppercased())  ·  \(phase.subtitle)")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(node.color)
                    }
                    Spacer()
                }

                Divider().opacity(0.3)

                ScrollView {
                    WickMarkdown(text: msg.content, accent: node.color)
                        .padding(.trailing, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(node.color.opacity(0.35), lineWidth: 1)
            )
            .frame(minHeight: 520)
            .id(id) // animate-in on switch
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
                Text("Pick a node on the left to read its full reasoning.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 520)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial.opacity(0.3))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
        }
    }

    /// One phase of the workflow: small phase label up top, then the
    /// member analysts as rows (divider between siblings only — no
    /// trailing divider so the cluster reads as one block).
    private func phaseSection(_ phase: AgentPhase, messages: [AgentMessage]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(phase.color.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(phase.title.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.9)
                    .foregroundStyle(.secondary)
                Text(phase.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.bottom, 10)
            ForEach(Array(messages.enumerated()), id: \.element.id) { idx, msg in
                agentRow(msg)
                    .padding(.vertical, 10)
                if idx < messages.count - 1 {
                    Divider().opacity(0.35)
                }
            }
        }
    }

    private func disclaimerRow(_ report: Report) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(report.disclaimer)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    /// Compact rating gauge — single horizontal track, 5 evenly
    /// spaced dots, active one enlarged with a dropped pill badge
    /// directly beneath it. Replaces the earlier full-width 5-segment
    /// bar (which wasted horizontal space and competed with the
    /// metric chips below for the eye).
    private func ratingGauge(_ rating: Rating) -> some View {
        let labels = ["Strong Sell", "Sell", "Hold", "Buy", "Strong Buy"]
        let tint = ratingColor(rating)
        return VStack(spacing: 12) {
            ZStack {
                // Thin track line connecting the dots end-to-end.
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 220, height: 1.5)
                HStack(spacing: 0) {
                    ForEach(Rating.allCases, id: \.self) { r in
                        let active = r == rating
                        ZStack {
                            // Active gets a soft halo behind the dot.
                            if active {
                                Circle()
                                    .fill(tint.opacity(0.28))
                                    .frame(width: 22, height: 22)
                                    .blur(radius: 3)
                            }
                            Circle()
                                .fill(active ? tint : Color.secondary.opacity(0.45))
                                .frame(width: active ? 12 : 6,
                                       height: active ? 12 : 6)
                                .overlay(
                                    Circle()
                                        .strokeBorder(active
                                            ? Color.white.opacity(0.25)
                                            : Color.clear,
                                            lineWidth: 1)
                                )
                                .shadow(color: active ? tint : .clear,
                                        radius: active ? 6 : 0)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: 220)
            }
            // Dropped badge for the active rating — anchored under
            // the active dot via a manual offset (5 dots evenly across
            // 220pt → step ~44pt; index 0..4 maps to -88..+88).
            HStack {
                Text(labels[rating.rawValue].uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tint.gradient))
                    .offset(x: CGFloat(rating.rawValue - 2) * 44)
            }
            .frame(width: 220)
        }
    }

    /// (Legacy multi-segment gauge kept for reference — unused.)
    @ViewBuilder
    private func legacyRatingGauge(_ rating: Rating) -> some View {
        let labels = ["Strong\nSell", "Sell", "Hold", "Buy", "Strong\nBuy"]
        HStack(alignment: .bottom, spacing: 5) {
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

    // MARK: Agent rows (avatar circle + name + body)

    /// One analyst's contribution. Avatar-style header:
    ///   - Circular gradient pill with the role's SF Symbol (the
    ///     closest native parallel to a memoji — Apple doesn't expose
    ///     a Memoji / Genmoji creation API on macOS, so SF Symbols
    ///     on gradient circles are the right macOS-native equivalent
    ///     for "analyst headshot")
    ///   - Role name + workflow phase pill on the right
    ///   - Content paragraph underneath in body type
    private func agentRow(_ msg: AgentMessage) -> some View {
        let style = roleStyle(msg.role)
        let phase = AgentPhase.from(role: msg.role)
        return HStack(alignment: .top, spacing: 12) {
            agentAvatar(style: style)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(msg.role)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(phase.title)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(style.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(
                            Capsule()
                                .strokeBorder(style.color.opacity(0.4),
                                              lineWidth: 0.8)
                        )
                }
                Text(msg.content)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
    }

    /// 36-pt circular avatar — radial gradient in the role's tint
    /// with the SF Symbol centered + a faint inner ring. Reads as
    /// "this is who is speaking" at a glance, like a headshot in a
    /// Slack thread, without committing to a real face.
    private func agentAvatar(style: (symbol: String, color: Color)) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [style.color.opacity(0.45),
                                 style.color.opacity(0.18)],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: 36)
                )
            Circle()
                .strokeBorder(style.color.opacity(0.55),
                              lineWidth: 1)
            Image(systemName: style.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(style.color)
        }
        .frame(width: 34, height: 34)
    }

    // MARK: Workflow phase grouping

    /// The four logical phases of the multi-agent desk workflow.
    /// Order here is rendering order (and roughly chronological:
    /// information → debate → synthesis → gatekeep).
    enum AgentPhase: String, CaseIterable, Identifiable, Hashable {
        case analysts  = "Analysts"
        case research  = "Research"
        case decision  = "Decision"
        case gatekeep  = "Risk"

        var id: String { rawValue }
        var title: String { rawValue }

        /// One-liner under the phase header to remind the user what
        /// happens at this stage. Same vocabulary the engine uses.
        var subtitle: String {
            switch self {
            case .analysts: return "Information gathering"
            case .research: return "Bull vs Bear debate"
            case .decision: return "Trade synthesis"
            case .gatekeep: return "Risk gate"
            }
        }

        /// Phase accent — drives the leading dot + the agent name's
        /// phase pill colour. Kept distinct from each role's own
        /// accent so the phase reads as group-membership, not
        /// individual identity.
        var color: Color {
            switch self {
            case .analysts: return .blue
            case .research: return .indigo
            case .decision: return .orange
            case .gatekeep: return .gray
            }
        }

        static func from(role: String) -> AgentPhase {
            switch role {
            case "Fundamental Analyst", "Technical Analyst",
                 "Sentiment Analyst",   "News Analyst":
                return .analysts
            case "Bull Researcher", "Bear Researcher":
                return .research
            case "Trader":
                return .decision
            case "Risk Manager":
                return .gatekeep
            default:
                return .analysts
            }
        }

        /// Group a flat transcript by phase, preserving each phase's
        /// internal order. Returns a dictionary so callers can iterate
        /// `AgentPhase.allCases` and ask for the bucket they want.
        static func partition(_ messages: [AgentMessage])
            -> [AgentPhase: [AgentMessage]]
        {
            var out: [AgentPhase: [AgentMessage]] = [:]
            for msg in messages {
                out[from(role: msg.role), default: []].append(msg)
            }
            return out
        }
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
    ///
    /// Also forces a layout-pass replay using the chart's current total
    /// pixel height. Without this, adding a brand-new sub-pane (Stochastic,
    /// another MACD, etc) silently fails to render: the new `PaneSpec`
    /// lands in `coordinator.panes`, but `coordinator.priceScales` has no
    /// entry for that `PaneID`, so `IndicatorOverlay`'s
    /// `guard let scale = priceScales[paneID]` skips the indicator and the
    /// user sees no visual update. `setLayout(...)` walks the panes and
    /// creates a fresh `PriceScale` for any missing entry, which is the
    /// piece the autoscaler then fills with a y-range.
    static func syncIndicators(coordinator: ChartCoordinator,
                               config: ChartIndicatorConfig)
    {
        let oldPanes = coordinator.panes
        coordinator.indicators = config.instances
        coordinator.panes = config.derivedPanes

        let gutter: CGFloat = 4
        var totalHeight: CGFloat = 0
        for spec in oldPanes {
            totalHeight += coordinator.priceScales[spec.id]?.height ?? 0
        }
        totalHeight += gutter * CGFloat(max(0, oldPanes.count - 1))
        if coordinator.timeScale.width > 0 && totalHeight > 0 {
            coordinator.setLayout(width: coordinator.timeScale.width,
                                  height: totalHeight,
                                  gutter: gutter)
        }
        // The autoscaler is gated on `autoscaleYOnPan` for normal pans;
        // force a recompute here so the new sub-pane's y-range is
        // available the instant the indicator is added.
        coordinator.autoscaleIfNeeded(force: true)
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
