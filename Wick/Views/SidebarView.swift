import SwiftUI
import CoreCharts
import DataAdapters

/// Watchlist sidebar. Hosted inside `NavigationSplitView`; the parent
/// supplies the `.searchable` binding, so this view just lists the
/// (already-filtered) tickers and reports selection. macOS / iOS render
/// the surrounding sidebar surface in Liquid Glass automatically.
struct SidebarView: View {
    let tickers: [Ticker]
    @Binding var route: SidebarRoute?
    @Binding var searchQuery: String
    let searchResults: [YahooSearchResult]
    let onPickResult: (YahooSearchResult) -> Void
    @Bindable var watchlist: WatchlistStore
    let holdingsCount: Int
    /// Symbols that are fully closed (net 0) — only flagged with a "已平仓"
    /// marker while viewing the Holdings list.
    var closedHoldingSymbols: Set<String> = []
    @State private var showSparkline: Bool = true
    @State private var newGroupPromptShown: Bool = false
    @State private var newGroupName: String = ""

    /// Sparkline drops out when the sidebar narrows below this point.
    private let sparklineMinWidth: CGFloat = 240

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                List(selection: $route) {
                    Section {
                        portfolioRow
                            .tag(SidebarRoute.portfolio)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                        wickerRow
                            .tag(SidebarRoute.wicker)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                        marketRow
                            .tag(SidebarRoute.market)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                    }
                    Section {
                        ForEach(tickers) { ticker in
                            TickerRow(ticker: ticker,
                                      showSparkline: showSparkline,
                                      isClosed: watchlist.selection == .holdings
                                          && closedHoldingSymbols.contains(ticker.symbol))
                                .tag(SidebarRoute.ticker(ticker.id))
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .contextMenu {
                                    tickerContextMenu(for: ticker)
                                }
                        }
                    } header: {
                        watchlistSectionHeader
                    }
                    if !searchResults.isEmpty {
                        Section("Search Results") {
                            ForEach(searchResults) { r in
                                SearchResultRow(result: r) { onPickResult(r) }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .onAppear { updateSparklineVisibility(width: proxy.size.width) }
            .onChange(of: proxy.size.width) { _, w in
                updateSparklineVisibility(width: w)
            }
        }
    }

    /// Manual search field hosted at the top of the sidebar. Reliable
    /// across NavigationSplitView quirks where `.searchable` placement
    /// sometimes ends up in the wrong column.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search stocks", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("SidebarSearchClear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .liquidGlass(cornerRadius: 7)
        .accessibilityLabel("Search stocks")
    }

    private func updateSparklineVisibility(width: CGFloat) {
        // Guard against the layout pass that sometimes reports width = 0
        // before constraints settle — would otherwise hide the sparkline
        // before the real value lands.
        guard width > 0 else { return }
        let next = width >= sparklineMinWidth
        if next != showSparkline { showSparkline = next }
    }

    // MARK: - Portfolio row

    /// Plain row — no trailing menu. Group switching / "New group…" /
    /// delete now live on the watchlist section header where they
    /// belong (next to the group name itself).
    private var portfolioRow: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.85),
                                 Color.accentColor.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                    .frame(width: 28, height: 28)
                Image(systemName: "rectangle.3.group.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Portfolio")
                    .font(.system(size: 14, weight: .semibold))
                Text("Holdings · P&L heatmap")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Watchlist section header

    /// Group name on the left, ellipsis menu on the right. The menu
    /// hosts both the group picker and the `+` (new group) /
    /// destructive delete actions — colocated with the name they
    /// affect so users don't hunt for them under "Portfolio".
    ///
    /// Typography matches the macOS-native sidebar section header
    /// (uppercase + tracked + tertiary tint, à la Apple's Finder /
    /// Mail / Stocks). The trailing menu uses just an ellipsis (no
    /// chevron) so it reads as a compact "more actions" affordance
    /// rather than a primary picker button.
    private var watchlistSectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(currentGroupTitle.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            groupMenu
        }
        .alert("New group", isPresented: $newGroupPromptShown) {
            TextField("Name", text: $newGroupName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                let n = newGroupName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return }
                let g = watchlist.addGroup(name: n)
                watchlist.selection = .user(g.id)
            }
        }
    }

    // MARK: - Wicker row (global chat — not tied to any ticker)

    /// Plain row to match the Portfolio row's visual weight — no
    /// glow, no symbol effect. The composer / typing-indicator
    /// downstream already carry the "AI is on" signalling; reusing
    /// it here just made the sidebar feel restless.
    private var wickerRow: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(
                        colors: [Color.purple.opacity(0.85),
                                 Color.indigo.opacity(0.60)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                    .frame(width: 28, height: 28)
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Wicker")
                    .font(.system(size: 14, weight: .semibold))
                Text("Chat · screening · macro")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Market row (passive page — sector heatmap / indices / macro)

    private var marketRow: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(
                        colors: [Color.orange.opacity(0.85),
                                 Color.pink.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                    .frame(width: 28, height: 28)
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Market")
                    .font(.system(size: 14, weight: .semibold))
                Text("Sectors · indices · macro")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var groupMenu: some View {
        Menu {
            // `.inline` renders the options FLAT inside this menu (with a
            // checkmark on the active one) instead of the default `.menu` style,
            // which nests them in a submenu — that submenu was the second expand
            // the user had to do just to switch lists. Now: open the ⋯ menu →
            // pick a group directly, one expand.
            Picker("Group", selection: $watchlist.selection) {
                // Holdings pinned to the TOP — it's the user's own positions, the
                // most-returned-to list, so it leads regardless of how many user
                // groups exist. Then "All" (every tracked stock across all groups
                // in one list), then the user's groups.
                Label("Holdings (\(holdingsCount))", systemImage: "rectangle.3.group")
                    .tag(WatchlistGroupSelection.holdings)
                Label("All", systemImage: "tray.full")
                    .tag(WatchlistGroupSelection.all)
                ForEach(watchlist.groups) { group in
                    Label("\(group.name) (\(group.symbols.count))",
                          systemImage: "folder")
                        .tag(WatchlistGroupSelection.user(group.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button {
                newGroupName = ""
                newGroupPromptShown = true
            } label: {
                Label("New group…", systemImage: "plus")
            }
            if case .user(let id) = watchlist.selection {
                Button(role: .destructive) {
                    watchlist.remove(id: id)
                } label: {
                    Label("Delete current group", systemImage: "trash")
                }
            }
        } label: {
            // Single ellipsis matches macOS sidebar "more" affordance
            // (Finder tags, Mail mailbox row, Stocks watchlist). A
            // 18×18 frame gives the hit target enough breathing room
            // without painting visible padding around the glyph; the
            // `.borderlessButton` menu style already paints its own
            // subtle hover state inside that frame.
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch watchlist group · \(currentGroupTitle)")
        .accessibilityLabel("Watchlist group actions")
        .accessibilityIdentifier("SidebarGroupMenu")
    }

    private var currentGroupTitle: String {
        switch watchlist.selection {
        case .all:      return String(localized: "All", locale: LocaleHolder.current)
        case .holdings: return String(localized: "Holdings", locale: LocaleHolder.current)
        case .user(let id):
            return watchlist.groups.first(where: { $0.id == id })?.name ?? String(localized: "Group", locale: LocaleHolder.current)
        }
    }

    @ViewBuilder
    private func tickerContextMenu(for ticker: Ticker) -> some View {
        if watchlist.groups.isEmpty {
            Text("No user groups yet")
        } else {
            ForEach(watchlist.groups) { group in
                let isMember = group.symbols.contains(ticker.symbol)
                Button {
                    watchlist.toggle(symbol: ticker.symbol, in: group.id)
                } label: {
                    Label(isMember ? String(localized: "Remove from \(group.name)", locale: LocaleHolder.current)
                                   : String(localized: "Add to \(group.name)", locale: LocaleHolder.current),
                          systemImage: isMember ? "minus.circle" : "plus.circle")
                }
            }
        }
    }
}

// MARK: - Row

private struct TickerRow: View {
    let ticker: Ticker
    let showSparkline: Bool
    /// Fully-closed holding (net 0) — shows a dimmed "已平仓" marker.
    var isClosed: Bool = false
    @Environment(LiveDataStore.self) private var store
    @Environment(AgentSettings.self) private var settings

    var body: some View {
        let liveSeries = store.series(for: ticker.symbol,
                                      interval: .d1,
                                      fallback: ticker.dailySeries)
        let closes = liveSeries.candles.suffix(22).map(\.close)
        let baseline = closes.first
        let lastPrice = liveSeries.candles.last?.close ?? ticker.lastPrice
        let isUp = (lastPrice >= (baseline ?? lastPrice))
        let tint = isUp ? Color.green : Color.red
        let change = closes.last.flatMap { last in baseline.map { last - $0 } } ?? 0
        // Yesterday's close — used by the "Percent" pill style so the
        // percent reflects today's move instead of the trailing 22-day
        // window. The absolute-delta + sparkline still ride the 22d
        // window since that matches the tint signal a glance away.
        let previousClose: Double? = closes.count >= 2 ? closes[closes.count - 2] : nil
        let dayChange: Double = previousClose.map { lastPrice - $0 } ?? change

        HStack(spacing: 12) {
            symbolBlock
                .frame(maxWidth: .infinity, alignment: .leading)

            if showSparkline {
                SparklineView(closes: Array(closes),
                              baseline: baseline,
                              style: .area,
                              tint: tint,
                              lineWidth: 1.5)
                    .frame(width: 72, height: 26)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }

            priceBlock(lastPrice: lastPrice,
                       change: change,
                       dayChange: dayChange,
                       previousClose: previousClose,
                       tint: tint)
        }
        .padding(.vertical, 4)
        .animation(.snappy(duration: 0.18), value: showSparkline)
        .accessibilityLabel("\(ticker.symbol), \(ticker.name)")
        .accessibilityValue(
            "\(String(format: "%.2f", lastPrice)) dollars, change " +
            "\(change >= 0 ? "up" : "down") \(String(format: "%.2f", abs(change)))"
        )
    }

    private var symbolBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(ticker.symbol)
                    .font(.system(size: 16, weight: .semibold))
                if isClosed {
                    // Dimmed "已平仓" chip so a fully-closed (net-0) holding reads
                    // as history at a glance while still living in the list.
                    Text("Closed")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
            }
            Text(ticker.name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // Fade the whole closed row slightly so live rows lead the eye.
        .opacity(isClosed ? 0.6 : 1)
    }

    private func priceBlock(lastPrice: Double,
                            change: Double,
                            dayChange: Double,
                            previousClose: Double?,
                            tint: Color) -> some View
    {
        VStack(alignment: .trailing, spacing: 4) {
            Text(String(format: "%.2f", lastPrice))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(formattedChange(change: change,
                                  dayChange: dayChange,
                                  previousClose: previousClose))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(tint))
        }
    }

    /// Render the watchlist row's change pill per the Settings → Display
    /// preference. `.absolute` shows the trailing window's absolute
    /// price delta (matches the sparkline). `.percent` shows the TRUE
    /// day-over-day percent so the number lines up with what every
    /// other stock app surfaces on a row at a glance.
    private func formattedChange(change: Double,
                                 dayChange: Double,
                                 previousClose: Double?) -> String {
        switch settings.watchlistChangeStyle {
        case .absolute:
            return (change >= 0 ? "+" : "") + String(format: "%.2f", change)
        case .percent:
            guard let prev = previousClose, prev != 0 else {
                // First-day window with no prior close yet — fall back
                // to absolute delta rather than a misleading 0%.
                return (change >= 0 ? "+" : "") + String(format: "%.2f", change)
            }
            let pct = dayChange / prev * 100
            return String(format: "%+.2f%%", pct)
        }
    }
}

// MARK: - Search result row

private struct SearchResultRow: View {
    let result: YahooSearchResult
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.symbol)
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 6) {
                    Text(result.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let ex = result.exchangeLabel, !ex.isEmpty {
                        Text(ex)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { onAdd() }
        .accessibilityLabel("\(result.symbol), \(result.displayName)")
        .accessibilityHint("Adds to watchlist")
    }
}
