import SwiftUI
import TradingFloor

// MARK: - Capital (资金) tab

/// Per-stock **资金** tab — surfaces the free EastMoney (东方财富) A-share / HK
/// data the chat agent already uses, rendered as three Liquid-Glass cards:
///
///   • **资金流 · 主力动向** — latest day's 主力净流入 (亿) + 主力净占比%, a compact
///     multi-day mini-bar row, and the 超大单/大单/中单/小单 split.
///   • **财务** — latest `FinanceReport`: 营收 / 归母净利 (+同比), EPS, ROE,
///     毛利率/净利率, 资产负债率, 每股净资产, plus a revenue/profit sparkline.
///   • **龙虎榜** — recent billboard appearances for this stock.
///
/// **CN-only.** The whole tab is gated upstream (`DetailTab.tabs(for:)` hides
/// it for non-CN tickers), so this view is only ever instantiated for a ticker
/// `CNSymbol.parse` recognises. It still fetches defensively via
/// `EastMoneyExtrasProvider`, which itself returns `[]` for ineligible markets.
///
/// **Best-effort.** Every fetch degrades to `[]` on failure — each card shows
/// "暂无数据" rather than an error, and there are no force-unwraps. Results are
/// cached in the view model keyed by symbol so re-appearing (tab switch /
/// scroll) doesn't refetch.
struct CapitalView: View {
    let ticker: Ticker

    @State private var model = CapitalModel()

    /// HK tickers (e.g. `0700.HK`) have no EastMoney 资金流 / 龙虎榜 — those are
    /// A-share-only datasets. For HK we show the 财务 card only.
    private var isHongKong: Bool {
        CNSymbol.market(ticker.symbol) == .hongKong
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.isLoading && !model.didLoadOnce {
                loadingState
            } else if isHongKong {
                // HK: 财务 only (no fund-flow / dragon-tiger on EastMoney).
                financialsCard
                Text("Fund flow / dragon-tiger are not available for HK tickers.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                fundFlowCard
                financialsCard
                dragonTigerCard
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
            Text("Loading capital data…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 48)
    }

    // MARK: - 资金流

    @ViewBuilder
    private var fundFlowCard: some View {
        card(header: "Fund Flow · Smart Money", icon: "arrow.left.arrow.right") {
            let days = model.fundFlow
            if let latest = days.last {
                let mainYi = latest.main
                let tint: Color = mainYi >= 0 ? .green : .red
                // Headline: 主力净流入 (亿) + 主力净占比 %.
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Main net inflow")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(Self.signedYi(mainYi))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(tint)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Main net %")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%+.2f%%", latest.mainPct))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(latest.mainPct >= 0 ? .green : .red)
                    }
                    if !latest.date.isEmpty {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("As of").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(latest.date)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Multi-day mini bar row — one bar per day, main net, +/- colored.
                if days.count > 1 {
                    miniBarRow(days)
                        .padding(.top, 4)
                }

                Divider().opacity(0.4).padding(.vertical, 2)

                // Order-size split (亿).
                let g = [GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: g, alignment: .leading, spacing: 8) {
                    splitMetric("Extra-large", latest.superBig)
                    splitMetric("Large", latest.big)
                    splitMetric("Medium", latest.medium)
                    splitMetric("Small", latest.small)
                }
            } else {
                emptyInline
            }
        }
    }

    /// One bar per day; height proportional to |main net|, colored by sign.
    private func miniBarRow(_ days: [EastMoneyExtrasProvider.FundFlowDay]) -> some View {
        let maxMag = max(days.map { abs($0.main) }.max() ?? 1, 1)
        return HStack(alignment: .center, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                let frac = CGFloat(abs(day.main) / maxMag)
                let tint: Color = day.main >= 0 ? .green : .red
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(tint.opacity(0.85))
                                .frame(height: max(3, geo.size.height * frac))
                        }
                    }
                    .frame(height: 40)
                    Text(Self.shortDate(day.date))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func splitMetric(_ label: LocalizedStringKey, _ valueYuan: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(Self.signedYi(valueYuan))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(valueYuan >= 0 ? .green : .red)
        }
    }

    // MARK: - 财务

    @ViewBuilder
    private var financialsCard: some View {
        card(header: "Financials", icon: "doc.text.magnifyingglass") {
            let reports = model.financials
            if let latest = reports.first {
                if let name = latest.reportName ?? latest.reportDate {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                let g = [GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: g, alignment: .leading, spacing: 10) {
                    metric("Revenue", Self.yiOrDash(latest.revenue), sub: Self.yoy(latest.revenueYoY))
                    metric("Net profit", Self.yiOrDash(latest.netProfit), sub: Self.yoy(latest.netProfitYoY))
                    metric("EPS", Self.numOrDash(latest.eps, suffix: String(localized: " CNY", locale: LocaleHolder.current)))
                    metric("ROE", Self.pctOrDash(latest.roe))
                    metric("Gross margin", Self.pctOrDash(latest.grossMargin))
                    metric("Net margin", Self.pctOrDash(latest.netMargin))
                    metric("Debt ratio", Self.pctOrDash(latest.debtRatio))
                    metric("BPS", Self.numOrDash(latest.bps, suffix: String(localized: " CNY", locale: LocaleHolder.current)))
                }

                // Revenue sparkline across returned periods (oldest → newest).
                let revs = reports.reversed().compactMap { $0.revenue }
                if revs.count > 2 {
                    Divider().opacity(0.4).padding(.vertical, 2)
                    HStack(spacing: 8) {
                        Text("Revenue trend")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        sparkline(revs)
                            .frame(height: 28)
                    }
                }
            } else {
                emptyInline
            }
        }
    }

    private func metric(_ label: LocalizedStringKey, _ value: String, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                if let sub, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(sub.hasPrefix("-") ? .red : .green)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Minimal line sparkline normalised to its own min/max.
    private func sparkline(_ values: [Double]) -> some View {
        GeometryReader { geo in
            let lo = values.min() ?? 0
            let hi = values.max() ?? 1
            let span = max(hi - lo, 1)
            let w = geo.size.width
            let h = geo.size.height
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = values.count <= 1 ? 0 : w * CGFloat(i) / CGFloat(values.count - 1)
                    let y = h - h * CGFloat((v - lo) / span)
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - 龙虎榜

    @ViewBuilder
    private var dragonTigerCard: some View {
        card(header: "Dragon-Tiger Board", icon: "list.star") {
            let entries = model.dragonTiger
            if entries.isEmpty {
                Text("No recent dragon-tiger listings")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                        billboardRow(e)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func billboardRow(_ e: EastMoneyExtrasProvider.BillboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(e.date)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                if let chg = e.changeRate {
                    Text(String(format: "%+.2f%%", chg))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(chg >= 0 ? .green : .red)
                }
                Spacer(minLength: 0)
                if let net = e.netAmount {
                    Text(String(localized: "Net buy ", locale: LocaleHolder.current) + Self.signedYi(net))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(net >= 0 ? .green : .red)
                }
            }
            if let reason = e.explanation, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let seat = e.explain, !seat.isEmpty {
                Text(seat)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.25)
        }
    }

    // MARK: - Shared card chrome

    @ViewBuilder
    private func card<Content: View>(
        header: LocalizedStringKey,
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

    /// Per-card "no data" inline state (EastMoney is best-effort).
    private var emptyInline: some View {
        Text("No data")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    // MARK: - Formatting (raw yuan → 亿/万)

    /// Signed 亿/万 string with a leading +/- (money is raw CNY).
    static func signedYi(_ yuan: Double) -> String {
        let sign = yuan >= 0 ? "+" : "-"
        return sign + fmtYi(abs(yuan))
    }

    /// Magnitude-only 亿/万 string (raw CNY). 1亿 = 1e8, 1万 = 1e4.
    static func fmtYi(_ yuan: Double) -> String {
        let v = abs(yuan)
        if v >= 1e8 { return String(format: "%.2f亿", yuan / 1e8) }
        if v >= 1e4 { return String(format: "%.2f万", yuan / 1e4) }
        return String(format: "%.0f", yuan)
    }

    static func yiOrDash(_ yuan: Double?) -> String {
        guard let yuan else { return "—" }
        return fmtYi(yuan)
    }

    static func pctOrDash(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2f%%", v)
    }

    static func numOrDash(_ v: Double?, suffix: String) -> String {
        guard let v else { return "—" }
        return String(format: "%.2f", v) + suffix
    }

    /// Year-over-year growth tag, e.g. "+12.3%" / "-4.0%" / "" when nil.
    static func yoy(_ v: Double?) -> String {
        guard let v else { return "" }
        return String(format: "%+.1f%%", v)
    }

    /// "2026-06-12" → "06-12" for the compact bar labels.
    static func shortDate(_ s: String) -> String {
        let parts = s.split(separator: "-")
        if parts.count == 3 { return "\(parts[1])-\(parts[2])" }
        return String(s.suffix(5))
    }
}

// MARK: - View model

/// View-local cache + fetch state for the 资金 tab. Keyed by symbol so a tab
/// switch / re-appear within the same ticker reuses the last result instead of
/// re-hitting EastMoney. `@Observable` so the view tracks `isLoading` and the
/// three result arrays. All fetches are best-effort — failures surface as empty
/// arrays, never an error.
@Observable
@MainActor
final class CapitalModel {
    private(set) var fundFlow: [EastMoneyExtrasProvider.FundFlowDay] = []
    private(set) var financials: [EastMoneyExtrasProvider.FinanceReport] = []
    private(set) var dragonTiger: [EastMoneyExtrasProvider.BillboardEntry] = []
    private(set) var isLoading = false
    private(set) var didLoadOnce = false

    /// Symbol whose results are currently held (cache key).
    private var loadedSymbol: String?

    /// One shared provider — Foundation-only, no key, internally rate-limited.
    private let provider = EastMoneyExtrasProvider()

    /// Fetch on appear unless we already hold this symbol's results. The three
    /// fetches run concurrently; each degrades to `[]` independently.
    func load(symbol: String) async {
        if loadedSymbol == symbol, didLoadOnce { return }   // cache hit
        isLoading = true
        async let flow = provider.fundFlow(symbol: symbol, days: 5)
        async let fin = provider.financials(symbol: symbol, periods: 6)
        async let dt = provider.dragonTiger(symbol: symbol, pageSize: 10)
        let (f, n, d) = await (flow, fin, dt)
        // Guard against an out-of-order completion after a fast ticker switch.
        guard !Task.isCancelled else { return }
        fundFlow = f
        financials = n
        dragonTiger = d
        loadedSymbol = symbol
        didLoadOnce = true
        isLoading = false
    }
}
