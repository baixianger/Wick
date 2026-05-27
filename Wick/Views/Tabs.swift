import SwiftUI
import Accessibility
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

// MARK: - Agent workflow phase

/// The four logical phases of the multi-agent desk workflow.
/// Order here is rendering order (and roughly chronological:
/// information → debate → synthesis → gatekeep).
///
/// Lifted to file scope so the workflow stepper and lean consensus
/// strip (separate files) can reference it without going through the
/// AITab namespace.
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

    /// SF Symbol per phase — used by the workflow stepper as the
    /// node glyph so the four steps are recognisable without reading
    /// the label first.
    var symbol: String {
        switch self {
        case .analysts: return "magnifyingglass"
        case .research: return "bubble.left.and.bubble.right"
        case .decision: return "checkmark.seal"
        case .gatekeep: return "shield.lefthalf.filled"
        }
    }

    /// Phase accent — all phases share the system accent so the
    /// workflow stepper reads as one unified control (Apple HIG
    /// "let semantic colors carry meaning; phase identity is
    /// already conveyed by symbol + label"). State (running /
    /// complete / warning) does the visual heavy lifting, not
    /// phase identity.
    var color: Color { Color.accentColor }

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

    /// Map a runner stage string (as emitted by `TradingFloor.analyze`
    /// or `WickServer`'s SSE stream) to the workflow phase the user
    /// is currently in. Used by the stepper to highlight the active
    /// node during a live run. Returns `nil` when the stage doesn't
    /// belong to a known phase (e.g. "Gathering market data" is
    /// pre-workflow setup).
    static func fromStage(_ stage: String) -> AgentPhase? {
        let lower = stage.lowercased()
        if lower.contains("analyst") { return .analysts }
        if lower.contains("debate") || lower.contains("bull")
            || lower.contains("bear") || lower.contains("research") {
            return .research
        }
        if lower.contains("trader") || lower.contains("decision")
            || lower.contains("trade ") {
            return .decision
        }
        if lower.contains("risk") || lower.contains("gate") {
            return .gatekeep
        }
        return nil
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

    /// The desk runner for this ticker — lives on the history store
    /// rather than as `@State` here so a run survives the user
    /// navigating to another ticker and back (the AITab view is
    /// `.id(ticker.id)`-rebuilt by DetailView; an `@State` runner
    /// would be discarded mid-run).
    private var runner: DeskRunner {
        history.runner(for: ticker.symbol)
    }
    /// Which historical report's full transcript is shown. `nil` =
    /// list-only view. Keyed by `generatedAt` since `Report` has no
    /// id and timestamps are unique per (ticker, run). Lifted to
    /// `DetailView` so the right-side inspector and this pane share
    /// one source of truth.
    @Binding var expanded: Date?
    /// History inspector visibility. Toggled by the header pill;
    /// owned by `DetailView` so `.inspector(isPresented:)` can sit
    /// outside the outer ScrollView (the only attachment point that
    /// lays out correctly on macOS).
    @Binding var historyOpen: Bool

    /// Which analyst cards are currently expanded inline. Default is
    /// "all collapsed" — the consensus strip + headlines already
    /// communicate each stance, so the full markdown is on-demand.
    @State private var expandedAnalysts: Set<UUID> = []

    /// Which debate turns the user has explicitly collapsed. Debate
    /// is expanded by default (it's the whole point), so the set
    /// tracks the inversion — empty means "everything open".
    @State private var collapsedDebate: Set<UUID> = []

    /// Respect the system "Reduce motion" accessibility toggle.
    /// Animations across the tab gate on this so users with
    /// vestibular sensitivities don't get the slide/spring shows.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var historyForTicker: [Report] {
        history.reports(for: ticker.symbol)
    }

    var body: some View {
        let items = historyForTicker
        let activeReport = activeReport(in: items)
        return ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 18) {
                // LEFT — main report column. Stays at maxWidth so the
                // analyst grid + verdict band have room to breathe; the
                // right history column tucks against its trailing edge.
                VStack(alignment: .leading, spacing: 14) {
                    header(historyCount: items.count,
                            activeReport: activeReport,
                            proxy: proxy)
                    if items.isEmpty {
                        emptyState
                    } else if let target = activeReport {
                        reportView(target)
                            .id(target.generatedAt) // re-mount per report switch
                    }
                    // Inline error strip — kept here for the failed-run case;
                    // the stepper alone can't communicate the error message.
                    if case .failed(let message) = runner.phase {
                        failedRunStrip(message)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                // RIGHT — vertical history column. Visible when
                // `historyOpen` is on AND there's at least one report.
                // Collapses with a slide-out animation so the report
                // can take the full width when the user wants focus.
                if historyOpen && !items.isEmpty {
                    historyColumn(items)
                        .frame(width: 280)
                        .transition(reduceMotion ? .identity
                            : .move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        // Announce live workflow stage transitions to VoiceOver. The
        // visual stepper highlights the active node, but blind users
        // need a spoken cue when the desk moves from "Analysts at
        // work" → "Bull/bear debate, round 1" → "Risk review", etc.
        .onChange(of: currentRunStage) { _, stage in
            guard let stage else { return }
            var announcement = AttributedString("Workflow: \(stage)")
            announcement.accessibilitySpeechAnnouncementPriority = .default
            AccessibilityNotification.Announcement(announcement).post()
        }
        .onAppear {
            // Default-expand the most recent report when entering the
            // tab so the page never opens blank if there's history.
            // The runner's `onCompleted` hook is wired by the history
            // store (see `ReportHistoryStore.runner(for:)`), so a run
            // that finishes while AITab is offscreen still lands in
            // the archive; the next time the user opens this tab the
            // default-latest line below picks it up.
            let items = historyForTicker
            if expanded == nil, let latest = items.first {
                expanded = latest.generatedAt
            }
            // Two-column default: when this ticker has prior reports,
            // open the right history column on entry. Empty history →
            // single column so the "no analyses yet" empty state takes
            // the full width without dead chrome on the right.
            if !items.isEmpty, !historyOpen {
                historyOpen = true
            }
        }
        // When a run started elsewhere completes for this ticker, jump
        // the selection to it so the user lands on the fresh report.
        .onChange(of: history.reports(for: ticker.symbol).first?.generatedAt) {
            _, latest in
            if let latest, expanded != latest {
                expanded = latest
                // Don't auto-close the inspector here — user may be
                // mid-browse comparing older reports. They explicitly
                // toggle the history pill when they're done.
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

    private func header(historyCount: Int,
                         activeReport: Report?,
                         proxy: ScrollViewProxy) -> some View
    {
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
            Text("AI Analysis")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            // Inline compact workflow stepper — sits between the
            // title and the Run button so the user sees the desk's
            // process *in the same row* as the trigger that drives it.
            // Tap a node to scroll to the corresponding report section.
            WorkflowStepper(
                phases: AgentPhase.allCases,
                statusFor: { phase in
                    stepperStatus(for: phase, report: activeReport)
                },
                onTap: { phase in
                    withAnimation(reduceMotion ? nil : .snappy) {
                        proxy.scrollTo(scrollAnchor(for: phase),
                                        anchor: .top)
                    }
                },
                compact: true)
                .layoutPriority(1)
                .padding(.horizontal, 6)
            Spacer(minLength: 0)
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
            withAnimation(reduceMotion ? nil : .spring(duration: 0.32)) {
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

    // MARK: - History column (right side of the two-column layout)

    /// Vertical history list. Replaces the earlier
    /// `.inspector(isPresented:)` side panel — being a real child of
    /// AITab means macOS no longer auto-injects a duplicate toggle
    /// into the detail-pane toolbar. Header row shows the count;
    /// each row is a tappable summary that switches `expanded`.
    private func historyColumn(_ items: [Report]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("History")
                    .font(.system(.subheadline, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items, id: \.generatedAt) { report in
                        historyRow(report)
                    }
                }
                .padding(.trailing, 2) // breathing room for scrollbar
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .opacity(0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    /// One row in the right-side history column. Active row gets a
    /// tinted background in the rating's colour so the user knows
    /// which report the left column is rendering.
    private func historyRow(_ report: Report) -> some View {
        let active = report.generatedAt == expanded
        let tint = ratingColor(report.rating)
        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                expanded = report.generatedAt
            }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.generatedAt.formatted(
                            date: .abbreviated, time: .shortened))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(report.rating.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? tint.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? tint.opacity(0.42) : Color.clear,
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(report.rating.label) on \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityAddTraits(active ? [.isSelected] : [])
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

    /// Map runner state + active report into a per-phase status for
    /// the workflow stepper. Order of precedence: live run > prior
    /// report > pending. The Risk node flips to `.warning` when the
    /// risk manager overrode the trader's call on the prior run.
    ///
    /// On `.failed`, we use `runner.lastStage` (captured by the
    /// runner's didSet on every `.running` transition) to mark the
    /// failed phase and leave earlier phases complete.
    private func stepperStatus(for phase: AgentPhase,
                                report: Report?) -> WorkflowStepper.Status
    {
        if case .running(let stage) = runner.phase {
            let active = AgentPhase.fromStage(stage)
            if active == phase { return .running }
            if let active, phaseIndex(phase) < phaseIndex(active) {
                return .complete
            }
            return .pending
        }
        if case .failed = runner.phase {
            if let stage = runner.lastStage,
               let failed = AgentPhase.fromStage(stage)
            {
                if phase == failed { return .failed }
                if phaseIndex(phase) < phaseIndex(failed) { return .complete }
                return .pending
            }
            return .pending
        }
        guard let report else { return .pending }
        return statusFromReport(report, phase: phase)
    }

    private func phaseIndex(_ phase: AgentPhase) -> Int {
        AgentPhase.allCases.firstIndex(of: phase) ?? 0
    }

    /// Active stage string when the runner is mid-flight; nil
    /// otherwise. Used by `.onChange` to drive the VoiceOver
    /// announcement.
    private var currentRunStage: String? {
        if case .running(let stage) = runner.phase { return stage }
        return nil
    }

    /// Stable scroll-anchor id per phase. The stepper's onTap calls
    /// `proxy.scrollTo(scrollAnchor(for: phase), anchor: .top)` and
    /// the matching section inside `reportView` carries the same
    /// `.id(...)`.
    private func scrollAnchor(for phase: AgentPhase) -> String {
        "AITab.section.\(phase.rawValue)"
    }

    /// Derive status from a completed report. Every phase represented
    /// in the transcript reads as complete; Risk flips to warning
    /// when the risk manager overrode the trader's call.
    private func statusFromReport(_ report: Report,
                                   phase: AgentPhase) -> WorkflowStepper.Status
    {
        let buckets = AgentPhase.partition(report.transcript)
        let hasMessages = !(buckets[phase] ?? []).isEmpty
        if phase == .gatekeep, hasMessages, riskOverrode(report) {
            return .warning(label: "risk override")
        }
        return hasMessages ? .complete : .pending
    }

    /// True iff the risk manager explicitly disagreed with the trader.
    /// `nil` means the field wasn't emitted — treat as agreement.
    private func riskOverrode(_ report: Report) -> Bool {
        guard let risk = report.transcript.first(where: { $0.role == "Risk Manager" })
        else { return false }
        return risk.agreesWithTrader == false
    }

    /// Inline failure strip beneath the stepper. The stepper itself
    /// shows the failed node visually; this row supplies the message
    /// and the retry affordance.
    @ViewBuilder
    private func failedRunStrip(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
            Button("Retry") {
                runner.run(ticker: ticker.symbol, settings: settings)
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.32), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Run failed: \(message)")
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

    /// Six-block information architecture mapped to the workflow:
    ///   1. Verdict capsule — rating (with override diff if any),
    ///      position bar, trader headline + body
    ///   2. Lean consensus strip — 4-cell analyst stance row
    ///   3. Debate thread — interleaved Bull/Bear turns by round
    ///   4. Analyst evidence — drill-in cards (collapsed by default)
    ///   5. Risk gate — promoted into capsule on override; tiny
    ///      "passed" pill when the manager agreed
    ///   6. Disclaimer
    ///
    /// Each agent body renders as-is markdown (LLM-free-form). Typed
    /// envelope fields (`lean`, `headline`, `rating`, `positionPercent`,
    /// `agreesWithTrader`, `proposedRating`) drive every structural
    /// decision — no substring guessing.
    private func reportView(_ report: Report) -> some View {
        let buckets = AgentPhase.partition(report.transcript)
        let analysts = (buckets[.analysts] ?? [])
            .sorted { sortKey($0.role) < sortKey($1.role) }
        let researchers = buckets[.research] ?? []
        let trader = report.transcript.first { $0.role == "Trader" }
        let risk = (buckets[.gatekeep] ?? []).first

        return VStack(alignment: .leading, spacing: 24) {
            // Decision (trader) anchors at the verdict capsule —
            // it's the trader's call materialised. Stepper's
            // Decision tap scrolls here.
            verdictBand(report, trader: trader, risk: risk)
                .id(scrollAnchor(for: .decision))
            if !researchers.isEmpty {
                section("Debate", subtitle: "Bull vs Bear, argued in rounds") {
                    debateThread(researchers)
                }
                .id(scrollAnchor(for: .research))
            }
            if !analysts.isEmpty {
                // Evidence section also serves as the "Analysts"
                // anchor — the section subtitle carries the lean
                // distribution summary (which the old standalone
                // strip used to surface). Each card header still
                // shows its lean chip, so the 4-cell consensus
                // strip would have been redundant.
                section("Evidence",
                         subtitle: analystConsensusSubtitle(analysts: analysts)) {
                    analystEvidence(analysts)
                }
                .id(scrollAnchor(for: .analysts))
            }
            // Risk gate is promoted into the verdict capsule on
            // override. On agreement we surface a tiny passed pill
            // here so the user still sees the gate happened.
            if let risk, !riskOverrode(report) {
                riskGatePassed(risk)
                    .id(scrollAnchor(for: .gatekeep))
            }
            disclaimerRow(report)
        }
    }

    /// Stable ordering for analyst grid: Fundamental → Technical →
    /// Sentiment → News. Anything unrecognized sinks to the end so a
    /// future analyst role doesn't break the 2×2 layout.
    private func sortKey(_ role: String) -> Int {
        switch role {
        case "Fundamental Analyst": return 0
        case "Technical Analyst":   return 1
        case "Sentiment Analyst":   return 2
        case "News Analyst":        return 3
        default:                    return 99
        }
    }

    // MARK: Layer 1 — Verdict capsule

    /// Single hero block. Top row: ticker + as-of. Middle row: rating
    /// chip (or override diff), position pill + allocation bar. Body:
    /// trader's headline + paragraph. Surface is `.regularMaterial`
    /// per HIG (content layer, not chrome).
    ///
    /// Risk override is promoted INTO the capsule: when the risk
    /// manager disagreed with the trader, the rating chip becomes a
    /// before/after diff (trader's rating struck through, risk's
    /// proposed rating active) and an amber ribbon sits along the
    /// top edge. This is the single most consequential fact on the
    /// page, so it gets prime real estate.
    private func verdictBand(_ report: Report,
                              trader: AgentMessage?,
                              risk: AgentMessage?) -> some View
    {
        let tint = ratingColor(report.rating)
        let headline = trader?.headline
        let body: String = {
            if let b = trader?.body, !b.isEmpty { return b }
            return strippedSummary(report.summary)
        }()
        let override = riskOverrideInfo(trader: trader, risk: risk,
                                         reportRating: report.rating)
        let activeRating = override?.finalRating ?? report.rating
        let activeTint = ratingColor(activeRating)

        return VStack(alignment: .leading, spacing: 0) {
            if let override {
                overrideRibbon(override)
            }
            VStack(alignment: .leading, spacing: 14) {
                // Ticker / as-of header
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(report.ticker)
                        .font(.system(.title, weight: .bold))
                    Text("· As of " + report.asOf.formatted(
                            date: .abbreviated, time: .omitted))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                // Rating chip + position bar
                HStack(alignment: .center, spacing: 14) {
                    if let override {
                        ratingDiffChip(from: override.traderRating,
                                        to: override.finalRating)
                    } else {
                        Text(report.rating.label.uppercased())
                            .font(.system(.subheadline, weight: .heavy))
                            .tracking(0.8)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(tint, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    if let pos = report.position {
                        positionBar(weight: pos.targetWeight, tint: activeTint)
                            .frame(maxWidth: 240)
                    }
                    Spacer()
                }

                if let headline, !headline.isEmpty {
                    Text(headline)
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 760, alignment: .leading)
                }
                if !body.isEmpty {
                    Text(body)
                        .font(.body)
                        .foregroundStyle(headline == nil ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                        .frame(maxWidth: 760, alignment: .leading)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        // Apple-Intelligence glow on the hero capsule — same effect
        // used on the AI Desk header icon. Signals "this surface is
        // the agent's verdict" rather than just another card. Always
        // active when a verdict exists; reduce-motion users still get
        // the static halo since `IntelligenceGlow` honors the env.
        .intelligenceGlow(active: true, cornerRadius: 14, intensity: 0.85)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(verdictBandAccessibilityLabel(
            for: report, headline: headline, override: override))
        .accessibilityAddTraits(.isHeader)
    }

    /// Captures the trader→risk rating delta when the risk manager
    /// overrode. Nil when risk agreed or didn't emit a typed verdict.
    private struct RiskOverrideInfo {
        let traderRating: Rating
        let finalRating: Rating
        let riskHeadline: String?
    }

    private func riskOverrideInfo(trader: AgentMessage?,
                                   risk: AgentMessage?,
                                   reportRating: Rating) -> RiskOverrideInfo?
    {
        guard let risk,
              risk.agreesWithTrader == false,
              let proposed = risk.proposedRating
        else { return nil }
        // Prefer the trader's typed rating; fall back to the rating
        // already stored on the Report (which `TradingFloor.analyze`
        // computed via the same envelope-first + parse-fallback flow,
        // so this is consistent regardless of which fallback fired).
        let traderRating = trader?.rating ?? reportRating
        return RiskOverrideInfo(traderRating: traderRating,
                                 finalRating: proposed,
                                 riskHeadline: risk.headline)
    }

    /// Subtle override notice along the top of the verdict capsule.
    /// Apple "alert tag" pattern: SF Symbol + bold text in semantic
    /// color, plain background. No filled colored strip, no border
    /// ribbon — the chip's `BUY → HOLD` diff already carries most of
    /// the visual weight; this line just names the event and the
    /// reason.
    private func overrideRibbon(_ override: RiskOverrideInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Risk override")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if let why = override.riskHeadline, !why.isEmpty {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 0)
    }

    /// Before/after rating chip. Trader's rating reads as a strike-
    /// through ghost; the risk-proposed rating is active. Designed to
    /// be read as "BUY → HOLD" by both sighted and VO users (the
    /// `.combine` on the parent capsule already labels the diff).
    private func ratingDiffChip(from old: Rating, to new: Rating) -> some View {
        let oldTint = ratingColor(old)
        let newTint = ratingColor(new)
        return HStack(spacing: 8) {
            Text(old.label.uppercased())
                .font(.system(.caption, weight: .semibold))
                .tracking(0.6)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    Capsule().fill(oldTint.opacity(0.12))
                )
                .foregroundStyle(oldTint.opacity(0.7))
                .strikethrough(true, color: oldTint.opacity(0.7))
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(new.label.uppercased())
                .font(.system(.subheadline, weight: .heavy))
                .tracking(0.8)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(newTint, in: Capsule())
                .foregroundStyle(.white)
        }
    }

    /// Slim allocation bar: filled portion = target weight, empty =
    /// remaining cash. Labelled with "20% · 80% cash" so the user
    /// reads both halves at a glance.
    private func positionBar(weight: Double, tint: Color) -> some View {
        let pct = Int((weight * 100).rounded())
        let cashPct = max(0, 100 - pct)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Position")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Text("\(pct)%")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text("· \(cashPct)% cash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(tint)
                        .frame(width: geo.size.width * CGFloat(weight))
                }
            }
            .frame(height: 6)
        }
    }

    /// Build the spoken summary for the verdict band. Stays compact so
    /// VoiceOver doesn't read for 20 seconds. Position is omitted when
    /// the trader declined to commit a number — matches the visual
    /// behaviour (no "0%" fallback). When risk overrode, the spoken
    /// summary leads with the override fact.
    private func verdictBandAccessibilityLabel(for report: Report,
                                                headline: String?,
                                                override: RiskOverrideInfo?) -> String
    {
        var parts: [String] = []
        if let override {
            parts.append(
                "Risk override, \(override.traderRating.label) changed to \(override.finalRating.label)")
        } else {
            parts.append("\(report.ticker) verdict")
            parts.append(report.rating.label)
        }
        if let pos = report.position {
            let pct = Int((pos.targetWeight * 100).rounded())
            parts.append("Position \(pct) percent")
        }
        if let headline, !headline.isEmpty {
            parts.append(headline)
        }
        return parts.joined(separator: ". ")
    }

    /// Five-dot inline gauge. Active dot in rating tint, others dim.
    /// The dots replace the old wide 220pt gauge — now they tuck into
    /// the same row as the rating chip + position, taking ~60pt.
    ///
    /// **Accessibility:** the dots are pure decoration — the rating
    /// chip beside them already announces the same value. We collapse
    /// them into one element with a single descriptive label, and add
    /// the `isImage` trait so VoiceOver treats it as a visual.
    private func inlineRatingDots(_ rating: Rating) -> some View {
        let tint = ratingColor(rating)
        return HStack(spacing: 6) {
            ForEach(Rating.allCases, id: \.self) { r in
                let active = r == rating
                Circle()
                    .fill(active ? tint : Color.secondary.opacity(0.32))
                    .frame(width: active ? 9 : 6,
                           height: active ? 9 : 6)
            }
        }
        .help("Strong Sell  ←  →  Strong Buy")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Rating gauge: \(rating.label) on a five-step scale from Strong Sell to Strong Buy.")
        .accessibilityAddTraits(.isImage)
    }

    // MARK: Layer 2 — Analyst consensus subtitle

    /// One-line subtitle for the Evidence section that summarises the
    /// lean distribution across the analysts. Example results:
    ///   "3 of 4 bullish · 1 bearish"
    ///   "Split: 2 bullish · 2 bearish"
    ///   "What each analyst found"   (when no typed leans available)
    ///
    /// Surfaces the macro signal the deleted `LeanConsensusStrip` used
    /// to provide, without re-rendering 4 cells whose role+lean are
    /// already in the card headers below.
    private func analystConsensusSubtitle(analysts: [AgentMessage]) -> String {
        var counts: [Lean: Int] = [:]
        for msg in analysts {
            if let l = extractedLean(from: msg) {
                counts[l, default: 0] += 1
            }
        }
        let bull = counts[.bullish] ?? 0
        let bear = counts[.bearish] ?? 0
        let neut = counts[.neutral] ?? 0
        let known = bull + bear + neut
        let total = analysts.count
        guard known > 0 else { return "What each analyst found" }

        var parts: [String] = []
        if bull > 0 { parts.append("\(bull) bullish") }
        if bear > 0 { parts.append("\(bear) bearish") }
        if neut > 0 { parts.append("\(neut) neutral") }
        // Lead with the dominant stance when there's a clear edge.
        if bull > bear, bull > neut {
            return "\(bull) of \(total) bullish · \(parts.dropFirst().joined(separator: " · "))"
                .trimmingCharacters(in: CharacterSet(charactersIn: "· "))
        }
        if bear > bull, bear > neut {
            return "\(bear) of \(total) bearish · \(parts.filter { !$0.hasSuffix("bearish") }.joined(separator: " · "))"
                .trimmingCharacters(in: CharacterSet(charactersIn: "· "))
        }
        // Split — no dominant side. Lead with "Split".
        return "Split: " + parts.joined(separator: " · ")
    }

    // MARK: Layer 3 — Debate thread

    /// Group bull and bear turns into rounds. The runner appends them
    /// strictly alternating (Bull, Bear, Bull, Bear, …) per
    /// `TradingFloor.analyze`, so we walk the array and pair them.
    /// Stragglers (e.g. a missing Bear in round N) render as a half
    /// round so the user still sees what was produced.
    private struct DebateRound: Identifiable {
        let id = UUID()
        let number: Int
        let bull: AgentMessage?
        let bear: AgentMessage?
    }

    private func roundsFromTranscript(_ msgs: [AgentMessage]) -> [DebateRound] {
        let bulls = msgs.filter { $0.role == "Bull Researcher" }
        let bears = msgs.filter { $0.role == "Bear Researcher" }
        let count = max(bulls.count, bears.count)
        return (0..<count).map { i in
            DebateRound(number: i + 1,
                         bull: i < bulls.count ? bulls[i] : nil,
                         bear: i < bears.count ? bears[i] : nil)
        }
    }

    /// Threaded debate view. Each round is a divider + Bull turn
    /// (green leading bar) + Bear turn (red leading bar). After the
    /// last round, the trader's body (when present) renders as a
    /// "Weighing" block so the decisive factor stays in the same
    /// reading thread as the arguments that led to it.
    @ViewBuilder
    private func debateThread(_ researchers: [AgentMessage]) -> some View {
        let rounds = roundsFromTranscript(researchers)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(rounds) { round in
                roundHeader(round.number, of: rounds.count)
                if let bull = round.bull {
                    debateTurn(bull, side: .bull)
                }
                if let bear = round.bear {
                    debateTurn(bear, side: .bear)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Debate transcript, \(rounds.count) rounds")
    }

    private enum DebateSide { case bull, bear
        var label: String { self == .bull ? "Bull" : "Bear" }
        var tint: Color { self == .bull ? .green : .red }
        var symbol: String {
            self == .bull ? "arrow.up.forward.circle.fill"
                          : "arrow.down.forward.circle.fill"
        }
    }

    private func roundHeader(_ n: Int, of total: Int) -> some View {
        HStack(spacing: 8) {
            Text("Round \(n)")
                .font(.caption.weight(.heavy))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
        }
        .padding(.top, n == 1 ? 0 : 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Round \(n) of \(total)")
        .accessibilityAddTraits(.isHeader)
    }

    /// One turn in the debate, rendered as a news-style card so the
    /// Debate and Evidence sections share the same visual grammar.
    /// Bull/Bear identity reads off the accent border + the small
    /// tinted dot in the source row. Default-expanded (debate is the
    /// whole point); tap header collapses.
    @ViewBuilder
    private func debateTurn(_ msg: AgentMessage, side: DebateSide) -> some View {
        let isCollapsed = collapsedDebate.contains(msg.id)
        Button {
            toggleDebate(msg.id)
        } label: {
            aiNewsCard(
                accent: side.tint,
                source: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(side.tint)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(side.label.uppercased())
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(side.tint)
                    }
                },
                headline: msg.headline,
                isExpanded: !isCollapsed,
                body: { WickMarkdown(text: displayBody(msg),
                                      accent: Color.secondary) }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(side.label) turn, \(msg.headline ?? "")")
        .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
        .accessibilityAddTraits(.isButton)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22),
                   value: isCollapsed)
    }

    private func toggleDebate(_ id: UUID) {
        if collapsedDebate.contains(id) {
            collapsedDebate.remove(id)
        } else {
            collapsedDebate.insert(id)
        }
    }

    // MARK: Layer 4 — Analyst evidence (drill-in grid)

    /// 2×2 grid of analyst cards. Each card collapsed by default to
    /// header + headline; tap to expand the full markdown body. The
    /// drill-in pattern keeps the page short on first read and lets
    /// the user dive into a specific stance.
    @ViewBuilder
    private func analystEvidence(_ analysts: [AgentMessage]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(analysts) { msg in
                analystCard(msg)
            }
        }
    }

    /// One analyst card — same news-style chrome as `NewsRow`. Source
    /// row (icon + role + optional lean chip) sits on top; headline
    /// renders large; body markdown is shown only when expanded. The
    /// expand/collapse state lives in `expandedAnalysts` (Set<UUID>).
    @ViewBuilder
    private func analystCard(_ msg: AgentMessage) -> some View {
        let style = roleStyle(msg.role)
        let lean = extractedLean(from: msg)
        let isExpanded = expandedAnalysts.contains(msg.id)
        Button {
            toggleAnalyst(msg.id)
        } label: {
            aiNewsCard(
                accent: style.color,
                source: {
                    HStack(spacing: 6) {
                        Image(systemName: style.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(style.color)
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityHidden(true)
                        Text(msg.role.uppercased())
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        if let lean {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            leanChip(lean)
                        }
                    }
                },
                headline: msg.headline,
                isExpanded: isExpanded,
                body: { WickMarkdown(text: displayBody(msg), accent: style.color) }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(msg.role), \(msg.headline ?? "")")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22),
                   value: isExpanded)
    }

    /// Shared news-style card chrome used by both Evidence and
    /// Debate. Mirrors `NewsRow`'s "source label / headline / body"
    /// vertical layout but adds an accent-tinted hairline border so
    /// bull/bear/analyst identity reads off the surround at a glance.
    private func aiNewsCard<Source: View, Body: View>(
        accent: Color,
        @ViewBuilder source: () -> Source,
        headline: String?,
        isExpanded: Bool,
        @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            source()
            if let h = headline, !h.isEmpty {
                Text(h)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(isExpanded ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isExpanded {
                body()
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.20), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func toggleAnalyst(_ id: UUID) {
        if expandedAnalysts.contains(id) {
            expandedAnalysts.remove(id)
        } else {
            expandedAnalysts.insert(id)
        }
    }

    // MARK: Layer 5 — Risk gate (passed case)

    /// Inline pill that says "the risk gate fired and agreed with the
    /// trader". Only shown when there was no override; the override
    /// case is promoted into the verdict capsule's ribbon.
    /// Compact "gate passed" line — `checkmark.shield` (hierarchical
    /// SF Symbol, secondary tint) + a tracked caption + optional
    /// headline. No green pill background. The pass case is reassurance,
    /// not an alert, so it doesn't deserve loud chrome.
    private func riskGatePassed(_ risk: AgentMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.callout)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Risk gate passed")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if let h = risk.headline, !h.isEmpty {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(h)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Risk gate passed. \(risk.headline ?? "")")
    }

    // MARK: Section wrapper

    /// Consistent section chrome: headline + optional subtitle, then
    /// the content with breathing room above. Uses system text styles
    /// (`.headline` + `.subheadline`) so Dynamic Type / accessibility
    /// settings carry through. Title-style capitalization per macOS 26
    /// section header convention.
    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                         subtitle: String? = nil,
                                         @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(.headline, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            content()
        }
    }

    private func disclaimerRow(_ report: Report) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(report.disclaimer)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    // MARK: Lean chip (typed → fallback substring)

    /// Visual properties for the three analyst stances. The enum itself
    /// lives in `TradingFloor` (`Lean`) — this is just the view layer's
    /// tint / glyph mapping.
    private func leanTint(_ lean: Lean) -> Color {
        switch lean {
        case .bullish: .green
        case .bearish: .red
        case .neutral: .gray
        }
    }

    private func leanSymbol(_ lean: Lean) -> String {
        switch lean {
        case .bullish: "arrow.up.right"
        case .bearish: "arrow.down.right"
        case .neutral: "minus"
        }
    }

    /// Resolve the agent's stance. Prefers the typed JSON envelope field
    /// (`msg.lean`); falls back to a substring scan of the raw content so
    /// older cached reports (pre-JSON-envelope) still render a chip.
    ///
    /// Returns nil only when neither path produced a value — UI then
    /// shows no chip. Never coerces to "neutral" as a fallback.
    private func extractedLean(from msg: AgentMessage) -> Lean? {
        if let typed = msg.lean { return typed }
        let lower = msg.content.lowercased()
        for lean in Lean.allCases {
            if lower.contains("lean: " + lean.rawValue) { return lean }
            if lower.contains("lean:" + lean.rawValue)  { return lean }
        }
        return nil
    }

    /// Subtle stance indicator — semantic dot + label, no capsule
    /// background. Apple "tag" pattern (Mail labels, Reminders flags):
    /// the dot carries the semantic color, the text reads as a
    /// neutral secondary label. Avoids three loud colored pills
    /// stacked next to each card header.
    private func leanChip(_ lean: Lean) -> some View {
        let tint = leanTint(lean)
        return HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(lean.rawValue.capitalized)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lean")
        .accessibilityValue(lean.rawValue.capitalized)
    }

    // MARK: Summary helpers

    /// Drop the redundant rating + position prefix from
    /// `Report.summary` so the verdict band's editorial paragraph
    /// doesn't repeat the chip beside it. Tolerates several shapes
    /// observed in cached reports:
    ///   - "HOLD\nPosition: 0%\n\n<paragraph>"   (AAPL)
    ///   - "SELL\n\n<paragraph>"                  (TSLA — no Position)
    ///   - "<paragraph>"                          (legacy)
    private func strippedSummary(_ summary: String) -> String {
        let verdicts: Set<String> = ["STRONG SELL", "SELL", "HOLD", "BUY",
                                      "STRONG BUY", "STRONG-SELL", "STRONG-BUY"]
        // Chars LLMs sometimes wrap verdicts in. Strip these from both
        // ends before comparing so `[BUY]`, `**HOLD**`, `「SELL」` etc.
        // all read as the bare verdict and get peeled off the summary.
        let stripChars: CharacterSet = CharacterSet(
            charactersIn: "[]()*_`【】「」《》\"' \t")
        var lines = summary.components(separatedBy: "\n")
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            let upperNaked = trimmed.uppercased()
                .trimmingCharacters(in: stripChars)
            if trimmed.isEmpty
                || verdicts.contains(upperNaked)
                || upperNaked.hasPrefix("POSITION:")
                || upperNaked.hasPrefix("ALLOC:")
                || upperNaked.hasPrefix("ALLOCATION:")
                || upperNaked.hasPrefix("TARGET WEIGHT")
            {
                lines.removeFirst()
                continue
            }
            break
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What to render inside an agent card's WickMarkdown view. Prefers
    /// the typed `msg.body` (set by `Agents.parseEnvelope`); falls back
    /// to the legacy "strip trailing `Lean:` line" routine for older
    /// cached reports where the envelope wasn't yet emitted.
    private func displayBody(_ msg: AgentMessage) -> String {
        if let body = msg.body, !body.isEmpty { return body }
        return strippedLeanLine(msg.content)
    }

    /// Legacy fallback: remove a trailing `Lean: ...` line from an
    /// agent's body so the chip in the card header doesn't read twice
    /// — once in the chip, once in the prose. If no Lean line is
    /// detected, returns the body unchanged. Kept only for pre-v2
    /// reports cached on disk.
    private func strippedLeanLine(_ body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        guard !lines.isEmpty else { return body }
        var trimmed = lines
        while let last = trimmed.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty
        {
            trimmed.removeLast()
        }
        if let last = trimmed.last,
           last.lowercased().contains("lean:")
        {
            trimmed.removeLast()
        }
        return trimmed.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SF Symbol + accent per desk role.
    private func roleStyle(_ role: String) -> (symbol: String, color: Color) {
        // Roles differentiate by SF Symbol, not color. Tints all
        // returned as `Color.secondary` so analyst cards stop being
        // a rainbow of teal/blue/purple/indigo — that "AI feel" comes
        // from many simultaneous accents. Apple HIG: let typography
        // and icon identity carry meaning; reserve color for state +
        // semantic axes (rating up/down, override).
        switch role {
        case "Fundamental Analyst": return ("building.columns", Color.secondary)
        case "Technical Analyst":   return ("chart.xyaxis.line", Color.secondary)
        case "Sentiment Analyst":   return ("bubble.left.and.bubble.right", Color.secondary)
        case "News Analyst":        return ("newspaper", Color.secondary)
        case "Bull Researcher":     return ("arrow.up.forward.circle", Color.secondary)
        case "Bear Researcher":     return ("arrow.down.forward.circle", Color.secondary)
        case "Trader":              return ("checkmark.seal", Color.secondary)
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

// MARK: - Analysis history inspector

/// Simple vertical list of past desk runs for the current ticker —
/// each row is just date + rating. Lives in `DetailView`'s
/// `.inspector(isPresented:)` slot so it occupies the scene-level
/// right column, never fighting the outer ScrollView for sizing.
struct AnalysisHistoryInspector: View {
    let symbol: String
    @Binding var expanded: Date?
    @Binding var historyOpen: Bool
    @Environment(ReportHistoryStore.self) private var history

    var body: some View {
        let items = history.reports(for: symbol)
        List(selection: Binding(
            get: { expanded },
            set: { new in if let new { expanded = new } }
        )) {
            ForEach(items, id: \.generatedAt) { report in
                row(report)
                    .tag(report.generatedAt)
            }
        }
        .listStyle(.inset)
        .overlay {
            if items.isEmpty {
                Text("No analyses yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    historyOpen = false
                } label: {
                    Label("Close history", systemImage: "sidebar.right")
                }
                .help("Hide history")
            }
        }
    }

    private func row(_ report: Report) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(report.generatedAt.formatted(
                        date: .abbreviated, time: .shortened))
                    .font(.callout.weight(.medium))
                Text(report.rating.label)
                    .font(.caption)
                    .foregroundStyle(ratingTint(report.rating))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func ratingTint(_ rating: Rating) -> Color {
        switch rating {
        case .strongSell: return .red
        case .sell:       return .orange
        case .hold:       return .gray
        case .buy, .strongBuy: return .green
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
