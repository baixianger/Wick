import SwiftUI
import CoreCharts

enum PortfolioTab: String, CaseIterable, Identifiable, Hashable {
    case heatmap      = "Heatmap"
    case positions    = "Positions"
    case transactions = "Transactions"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .heatmap:      return String(localized: "Heatmap", locale: LocaleHolder.current)
        case .positions:    return String(localized: "Positions", locale: LocaleHolder.current)
        case .transactions: return String(localized: "Transactions", locale: LocaleHolder.current)
        }
    }
}

struct PortfolioView: View {

    @Bindable var store: HoldingsStore
    @Environment(LiveDataStore.self) private var data
    @Environment(\.colorScheme) private var colorScheme

    @State private var editorMode: HoldingEditorSheet.Mode?
    @State private var sheetShown: Bool = false
    @State private var tab: PortfolioTab = .heatmap

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned chrome — header, summary, and tab picker stay
            // anchored at top while only the active tab's content
            // scrolls. Matches the pattern across MarketView /
            // DetailView so navigation is consistent.
            VStack(alignment: .leading, spacing: 22) {
                header
                summary
                FlatPicker(items: PortfolioTab.allCases,
                           selection: $tab,
                           label: { $0.label },
                           layout: .compact)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Group {
                        switch tab {
                        case .heatmap:      heatmapSection
                        case .positions:    positionsSection
                        case .transactions: transactionsSection
                        }
                    }
                    // Bottom safe area so the floating Wicker composer
                    // doesn't cover the last row.
                    Color.clear.frame(height: 72)
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appleBackground(for: colorScheme))
        .sheet(isPresented: $sheetShown) {
            HoldingEditorSheet(mode: editorMode ?? .add) { holding in
                switch editorMode {
                case .edit:
                    store.update(holding)
                default:
                    store.add(holding)
                }
            }
        }
        .onAppear { warmPrices() }
        .onChange(of: store.holdings) { _, _ in warmPrices() }
    }

    // MARK: - Header

    /// Title on the left, "+ Transaction" on the right. Used to be a
    /// bottom-trailing FAB but that collided with the global
    /// FloatingWickerComposer — macOS-native pattern is a toolbar /
    /// header button anyway (Mail Compose, Notes "+", Finder +).
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Portfolio")
                    .font(.system(size: 32, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editorMode = .add
                sheetShown = true
            } label: {
                Label("Transaction", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(LiquidGlassButtonStyle(prominent: true))
            .help("New transaction")
        }
    }

    private var subtitle: String {
        let positions = store.positions()
        let openCount = positions.filter { $0.netQuantity != 0 }.count
        let txCount = store.holdings.count
        if txCount == 0 {
            return String(localized: "Track buys and sells manually · live prices via Yahoo", locale: LocaleHolder.current)
        }
        return String(localized: "\(openCount) open · \(txCount) transaction\(txCount == 1 ? "" : "s") · live via Yahoo", locale: LocaleHolder.current)
    }

    // MARK: - Summary

    private var summary: some View {
        let totals = computeTotals()
        let ccy = store.holdings.first?.currency ?? "USD"
        return LazyVGrid(columns: Array(repeating:
                                            GridItem(.flexible(), alignment: .leading), count: 4),
                         alignment: .leading,
                         spacing: 16) {
            kv("Market value", money(totals.marketValue, ccy))
            kv("Cost basis",   money(totals.costBasis, ccy))
            kv("Unrealized P&L",
               (totals.unrealizedPnL >= 0 ? "+" : "") + money(totals.unrealizedPnL, ccy),
               tint: pnlTint(totals.unrealizedPnL))
            kv("Realized P&L",
               (totals.realizedPnL >= 0 ? "+" : "") + money(totals.realizedPnL, ccy),
               tint: pnlTint(totals.realizedPnL))
        }
    }

    private func kv(_ k: LocalizedStringKey, _ v: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(k)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(v)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(tint ?? .primary)
        }
    }

    // MARK: - Heatmap

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("P&L heatmap")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Cell area ∝ market value · color ∝ unrealized P&L %")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            let positions = openPositions()
            if positions.isEmpty {
                emptyState(
                    icon: "rectangle.3.group",
                    title: "No open positions",
                    body: String(localized: "Add a Buy transaction to see it on the heatmap, or load a sample portfolio to explore the page.", locale: LocaleHolder.current),
                    primaryAction: sampleAction
                )
            } else {
                TreemapView(tiles: heatmapTiles(positions: positions),
                            minLabelArea: 1200)
                    .chartTheme(appleTheme(for: colorScheme))
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func heatmapTiles(positions: [SymbolPosition]) -> [HeatTile] {
        positions.compactMap { p in
            let cur = currentPrice(symbol: p.symbol) ?? p.averageBuyPrice
            let value = abs(p.netQuantity * cur)
            guard value > 0 else { return nil }
            return HeatTile(id: p.symbol,
                            label: p.symbol,
                            secondary: p.name,
                            changePct: unrealizedPct(position: p, current: cur),
                            weight: value)
        }
    }

    // MARK: - Positions

    private var positionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Positions")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(openPositions().count) open")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)

            let positions = openPositions()
            if positions.isEmpty {
                emptyState(
                    icon: "tray",
                    title: "No open positions",
                    body: String(localized: "Add a transaction with the button above, or load a sample portfolio.", locale: LocaleHolder.current),
                    primaryAction: sampleAction
                )
            } else {
                ForEach(positions) { p in
                    positionRow(p)
                        .padding(.vertical, 10)
                    Divider().opacity(0.35)
                }
            }
        }
    }

    private func positionRow(_ p: SymbolPosition) -> some View {
        let cur = currentPrice(symbol: p.symbol)
        let unrealized = unrealizedPnL(position: p, current: cur)
        let pct = unrealizedPct(position: p, current: cur ?? p.averageBuyPrice)
        let tint = pnlTint(unrealized) ?? .secondary
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.symbol)
                        .font(.system(size: 14, weight: .semibold))
                    if p.isShort {
                        sideBadge(String(localized: "SHORT", locale: LocaleHolder.current), .red)
                    }
                }
                Text(p.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(localized: "Qty ", locale: LocaleHolder.current) + qty(p.netQuantity))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(String(localized: "Avg buy ", locale: LocaleHolder.current) + format2(p.averageBuyPrice))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(cur.map { format2($0) } ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                HStack(spacing: 4) {
                    Text((unrealized >= 0 ? "+" : "") + format2(unrealized))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Text(String(format: "(%+.2f%%)", pct))
                        .font(.system(size: 11, design: .rounded))
                        .opacity(0.75)
                }
                .foregroundStyle(tint)
            }
            .frame(width: 140, alignment: .trailing)
        }
    }

    // MARK: - Transactions

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transactions")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(store.holdings.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)

            ForEach(sortedTransactions()) { tx in
                transactionRow(tx)
                    .padding(.vertical, 8)
                Divider().opacity(0.35)
            }
        }
    }

    private func transactionRow(_ h: Holding) -> some View {
        HStack(spacing: 12) {
            sideBadge(h.side.label.uppercased(),
                      h.side == .buy ? .green : .red)
                .frame(width: 50, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(dateString(h.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(qty(h.quantity)) @ \(format2(h.price))")
                    .font(.system(size: 12, design: .rounded))
                Text(money(h.quantity * h.price, h.currency))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 2) {
                Button {
                    editorMode = .edit(h)
                    sheetShown = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit holding \(h.symbol)")
                .accessibilityIdentifier("HoldingEdit-\(h.id)")
                Button {
                    store.remove(id: h.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete holding \(h.symbol)")
                .accessibilityIdentifier("HoldingDelete-\(h.id)")
            }
            .padding(.leading, 6)
        }
    }

    private func sideBadge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(color))
    }

    // MARK: - Empty state

    /// Optional CTA payload for `emptyState`. When present the empty state
    /// renders a primary button under the body copy.
    private struct EmptyAction {
        let title: LocalizedStringKey
        let icon: String
        let handler: () -> Void
    }

    private var sampleAction: EmptyAction {
        EmptyAction(title: "Load sample portfolio",
                    icon: "sparkles") { store.loadSampleTransactions() }
    }

    @ViewBuilder
    private func emptyState(icon: String,
                            title: LocalizedStringKey,
                            body: String,
                            primaryAction: EmptyAction? = nil) -> some View
    {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let action = primaryAction {
                Button {
                    action.handler()
                } label: {
                    Label(action.title, systemImage: action.icon)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(LiquidGlassButtonStyle(prominent: true))
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Data plumbing

    private func warmPrices() {
        for sym in Set(store.holdings.map(\.symbol)) {
            _ = data.series(for: sym,
                            interval: .d1,
                            fallback: CandleSeries(symbol: sym, interval: .d1, candles: []))
        }
    }

    private func currentPrice(symbol: String) -> Double? {
        let s = data.series(for: symbol,
                            interval: .d1,
                            fallback: CandleSeries(symbol: symbol, interval: .d1, candles: []))
        return s.candles.last?.close
    }

    private func openPositions() -> [SymbolPosition] {
        store.positions().filter { $0.netQuantity != 0 }
    }

    private func sortedTransactions() -> [Holding] {
        store.holdings.sorted { $0.date > $1.date }
    }

    // MARK: - P&L

    private struct Totals {
        var marketValue: Double = 0
        var costBasis: Double = 0
        var unrealizedPnL: Double = 0
        var realizedPnL: Double = 0
    }

    private func computeTotals() -> Totals {
        var t = Totals()
        for p in openPositions() {
            let cur = currentPrice(symbol: p.symbol) ?? p.averageBuyPrice
            t.marketValue += p.netQuantity * cur
            t.costBasis += abs(p.netQuantity * p.averageBuyPrice)
            t.unrealizedPnL += unrealizedPnL(position: p, current: cur)
        }
        for p in store.positions() {
            t.realizedPnL += realizedPnL(position: p)
        }
        return t
    }

    private func unrealizedPnL(position p: SymbolPosition, current: Double?) -> Double {
        guard p.netQuantity != 0 else { return 0 }
        let cur = current ?? p.averageBuyPrice
        return (cur - p.averageBuyPrice) * p.netQuantity
    }

    private func unrealizedPct(position p: SymbolPosition, current: Double) -> Double {
        guard p.averageBuyPrice != 0 else { return 0 }
        let raw = (current - p.averageBuyPrice) / p.averageBuyPrice * 100
        return p.isShort ? -raw : raw
    }

    private func realizedPnL(position p: SymbolPosition) -> Double {
        let sells = store.transactions(for: p.symbol).filter { $0.side == .sell }
        return sells.reduce(0) { acc, sell in
            acc + (sell.price - p.averageBuyPrice) * sell.quantity
        }
    }

    private func pnlTint(_ v: Double) -> Color? {
        if v > 0 { return .green }
        if v < 0 { return .red }
        return nil
    }

    // MARK: - Formatting

    private func money(_ v: Double, _ ccy: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = ccy
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? format2(v)
    }
    private func qty(_ v: Double) -> String {
        let f = NumberFormatter()
        f.maximumFractionDigits = 4
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    private func format2(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
    private func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
