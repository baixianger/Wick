import SwiftUI
import TradingFloor

// MARK: - Short Interest (空头) tab

/// Per-stock **空头** tab — surfaces free FINRA Equity Short Interest for a
/// US-listed ticker, rendered as Liquid-Glass cards with history charts:
///
///   • **空头持仓 (short interest)** — latest shares short (humanised M/B) +
///     change % vs the prior settlement, and a BAR CHART of `shortShares`
///     across every settlement date in the window (the history the user asked
///     to plot).
///   • **天数覆盖 (days-to-cover)** — latest DTC + a line chart of the recent
///     history (squeeze proxy: higher = harder to cover). 999.99 sentinels are
///     already dropped by the provider.
///   • a small metrics row — ADV, venue, settlement date.
///
/// **US-only.** The whole tab is gated upstream (`DetailTab.tabs(for:)` shows
/// it only for bare US symbols), so this view is only ever built for a US
/// ticker. It still fetches defensively via `FINRAShortInterestProvider`, which
/// returns `[]` for anything the file doesn't cover.
///
/// **Best-effort.** The fetch degrades to `[]` on failure — the view shows an
/// empty state, never an error, and there are no force-unwraps. Results are
/// cached in the view model keyed by symbol so a tab switch / re-appear within
/// the same ticker doesn't refetch.
struct ShortInterestView: View {
    let ticker: Ticker

    @State private var model = ShortInterestModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.isLoading && !model.didLoadOnce {
                loadingState
            } else if model.points.isEmpty {
                emptyState
            } else {
                shortInterestCard
                daysToCoverCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: ticker.symbol) {
            await model.load(symbol: ticker.symbol)
        }
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L("Loading FINRA short-interest data…", "正在加载 FINRA 空头数据…"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 48)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.right.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(L("No FINRA short-interest data (US only, bi-monthly)", "无 FINRA 空头数据（仅美股，双月更新）"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 48)
    }

    // MARK: - 空头持仓

    @ViewBuilder
    private var shortInterestCard: some View {
        card(header: L("Short Interest", "空头持仓 · Short Interest"), icon: "arrow.down.right") {
            // Newest-first from the provider; the latest print drives headline.
            let points = model.points
            if let latest = points.first {
                // Rising short interest = more bearish positioning → red.
                let chg = latest.changePercent
                let chgTint: Color = (chg ?? 0) >= 0 ? .red : .green
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Shares short", "做空股数"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(Self.humanShares(latest.shortShares))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                    }
                    Spacer(minLength: 0)
                    if let chg {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(L("vs prior", "较上期"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(String(format: "%+.2f%%", chg))
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(chgTint)
                        }
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(L("Settlement", "结算日")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(latest.settlementDate)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                // History BAR chart — shortShares across settlement dates
                // (oldest → newest, left → right). This is the plotted history.
                let ordered = points.reversed().map { $0 }
                Divider().opacity(0.4).padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Shares-short history (\(ordered.count) periods, bi-monthly)", "做空股数历史（\(ordered.count) 期，双月更新）"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ShortInterestBarChart(values: ordered.map { $0.shortShares })
                        .frame(height: 96)
                    axisLabels(first: ordered.first?.settlementDate,
                               last: ordered.last?.settlementDate)
                }

                // Metrics row — ADV, venue.
                Divider().opacity(0.4).padding(.vertical, 2)
                HStack(spacing: 18) {
                    metric(L("Avg daily volume", "日均成交量"), latest.adv.map { Self.humanShares($0) } ?? "—")
                    if let venue = latest.venue, !venue.isEmpty {
                        metric(L("Venue", "上报场所"), venue)
                    }
                    metric(L("Coverage range", "覆盖区间"),
                           "\(ordered.first?.settlementDate ?? "—") → \(latest.settlementDate)")
                }
            }
        }
    }

    // MARK: - 天数覆盖

    @ViewBuilder
    private var daysToCoverCard: some View {
        card(header: L("Days-to-Cover", "天数覆盖 · Days-to-Cover"), icon: "clock.arrow.circlepath") {
            // Drop sentinel-stripped nils; keep paired dates for the line.
            let pairs = model.points.reversed().compactMap { p -> (String, Double)? in
                p.daysToCover.map { (p.settlementDate, $0) }
            }
            if let latest = model.points.first(where: { $0.daysToCover != nil }),
               let dtc = latest.daysToCover {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Days to cover", "回补天数"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(String(format: L("%.2f d", "%.2f 天"), dtc))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                    }
                    Spacer(minLength: 0)
                    Text(L("Higher days-to-cover = harder to unwind shorts (greater squeeze risk)", "回补天数越高 = 平掉空头越难（挤空风险越高）"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 180)
                }

                if pairs.count > 1 {
                    Divider().opacity(0.4).padding(.vertical, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Days-to-cover history", "回补天数历史"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        ShortInterestLineChart(values: pairs.map { $0.1 })
                            .frame(height: 64)
                        axisLabels(first: pairs.first?.0, last: pairs.last?.0)
                    }
                }
            } else {
                Text(L("No computable days-to-cover", "暂无可计算的回补天数"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Small parts

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
    }

    private func axisLabels(first: String?, last: String?) -> some View {
        HStack {
            Text(first.map(Self.shortDate) ?? "")
            Spacer(minLength: 0)
            Text(last.map(Self.shortDate) ?? "")
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }

    // MARK: - Shared card chrome

    @ViewBuilder
    private func card<Content: View>(
        header: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(header)
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 14)
    }

    // MARK: - Formatting

    /// Humanise a share count to K / M / B.
    static func humanShares(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1e9 { return String(format: "%.2fB", v / 1e9) }
        if a >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        if a >= 1e3 { return String(format: "%.1fK", v / 1e3) }
        return String(format: "%.0f", v)
    }

    /// "2026-05-29" → "05-29".
    static func shortDate(_ s: String) -> String {
        let parts = s.split(separator: "-")
        if parts.count == 3 { return "\(parts[1])-\(parts[2])" }
        return String(s.suffix(5))
    }
}

// MARK: - Charts (Canvas)

/// Bar chart of short-interest shares across settlement dates (left = oldest).
/// Bars are scaled from a zero baseline so the absolute level reads honestly.
private struct ShortInterestBarChart: View {
    let values: [Double]

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            guard !values.isEmpty, size.width > 0, size.height > 0 else { return }
            let hi = max(values.max() ?? 0, 0.0001)
            let gap: CGFloat = 2
            let n = values.count
            let barW = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * (barW + gap)
                let h = max(0.5, CGFloat(v / hi) * size.height)
                let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                // Most-recent bar accented; history muted.
                let isLast = i == n - 1
                ctx.fill(
                    Path(roundedRect: rect, cornerRadius: min(2, barW / 2)),
                    with: .color(isLast ? Color.red.opacity(0.9)
                                        : Color.red.opacity(0.45)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Line chart of days-to-cover across settlement dates, normalised to its own
/// min/max. A subtle filled area under the line gives the squeeze trend weight.
private struct ShortInterestLineChart: View {
    let values: [Double]

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            guard values.count > 1, size.width > 0, size.height > 0 else { return }
            let lo = values.min() ?? 0
            let hi = values.max() ?? 1
            let span = max(hi - lo, 0.0001)
            let w = size.width
            let h = size.height
            func pt(_ i: Int, _ v: Double) -> CGPoint {
                let x = w * CGFloat(i) / CGFloat(values.count - 1)
                let y = h - h * CGFloat((v - lo) / span)
                return CGPoint(x: x, y: y)
            }
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = pt(i, v)
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            // Filled area under the line.
            var area = line
            area.addLine(to: CGPoint(x: w, y: h))
            area.addLine(to: CGPoint(x: 0, y: h))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [Color.orange.opacity(0.25), Color.orange.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: h)))
            ctx.stroke(line, with: .color(.orange),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - View model

/// View-local cache + fetch state for the 空头 tab. Keyed by symbol so a tab
/// switch / re-appear within the same ticker reuses the last result instead of
/// re-hitting FINRA. `@Observable` so the view tracks `isLoading` + `points`.
/// Best-effort — a failure surfaces as an empty array, never an error.
@Observable
@MainActor
final class ShortInterestModel {
    private(set) var points: [FINRAShortInterestProvider.ShortInterestPoint] = []
    private(set) var isLoading = false
    private(set) var didLoadOnce = false

    /// Symbol whose results are currently held (cache key).
    private var loadedSymbol: String?

    /// One shared provider — Foundation-only, no key, single POST per lookup.
    private let provider = FINRAShortInterestProvider()

    /// Fetch on appear unless we already hold this symbol's results.
    func load(symbol: String) async {
        if loadedSymbol == symbol, didLoadOnce { return }   // cache hit
        isLoading = true
        let result = await provider.history(symbol: symbol, years: 2)
        // Guard against an out-of-order completion after a fast ticker switch.
        guard !Task.isCancelled else { return }
        points = result
        loadedSymbol = symbol
        didLoadOnce = true
        isLoading = false
    }
}
