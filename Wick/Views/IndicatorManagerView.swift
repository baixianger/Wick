import SwiftUI
import CoreCharts
import IndicatorKit

// MARK: - Indicator manager (used as sheet AND inside Settings)

/// Redesigned to match the Wick design language — Liquid Glass cards,
/// section-grouped list, prominent add-from-catalogue popover, and
/// inline-tag parameter editors instead of the cramped per-row
/// Stepper/Slider stack the old sheet shipped with.
///
/// The view is presentation-agnostic: the chart's "Indicators" button
/// pops it as a sheet, and `SettingsView`'s new "Indicators" tab
/// embeds it inline. Both surfaces edit the same shared
/// `ChartIndicatorConfig`, so what you change in one shows up in the
/// other immediately.
struct IndicatorManagerView: View {

    @Bindable var config: ChartIndicatorConfig

    /// `true` when hosted as a modal sheet — adds a "Done" close
    /// button. `false` when embedded inside Settings (no Done — close
    /// the window red dot dismisses).
    var presentedAsSheet: Bool = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAddPopover: Bool = false

    /// Group indicators by where they render so the user can reason
    /// about pane real-estate at a glance. Main-pane (price overlay)
    /// vs sub-pane (separate row below).
    private var groupedInstances: [(label: String, items: [IndicatorInstance])] {
        let main = config.instances.filter { $0.paneID == .main }
        let volume = config.instances.filter {
            if case .volume = $0.paneID { return true } else { return false }
        }
        let subs = config.instances.filter {
            if case .sub = $0.paneID { return true } else { return false }
        }
        var out: [(String, [IndicatorInstance])] = []
        if !main.isEmpty   { out.append(("ON PRICE",       main)) }
        if !volume.isEmpty { out.append(("ON VOLUME",      volume)) }
        if !subs.isEmpty   { out.append(("BELOW THE CHART", subs)) }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if config.instances.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(groupedInstances.enumerated()),
                                id: \.offset) { _, group in
                            section(label: group.label, items: group.items)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .background(appleBackground(for: colorScheme))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Indicators")
                    .font(.system(size: 20, weight: .bold))
                Text("\(config.instances.count) active  ·  drag to reorder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            addButton
            if presentedAsSheet {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, presentedAsSheet ? 18 : 4)
        .padding(.bottom, 14)
    }

    // MARK: - Add catalogue popover

    /// Replaces the toolbar Menu with a richer popover — categories
    /// rendered as Liquid Glass cards, descriptions visible so the
    /// user picks by intent not just by name.
    private var addButton: some View {
        Button {
            showAddPopover.toggle()
        } label: {
            Label("Add", systemImage: "plus")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(LiquidGlassButtonStyle(prominent: true))
        .popover(isPresented: $showAddPopover, arrowEdge: .bottom) {
            addCatalogue
                .frame(width: 360, height: 420)
        }
    }

    private var addCatalogue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(IndicatorCategory.allCases, id: \.self) { cat in
                    let items = IndicatorRegistry.shared.indicators(category: cat)
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(cat.label.uppercased())
                                .font(.system(size: 10, weight: .heavy))
                                .tracking(0.8)
                                .foregroundStyle(.tertiary)
                            VStack(spacing: 6) {
                                ForEach(items, id: \.identifier) { meta in
                                    catalogueRow(meta)
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private func catalogueRow(_ meta: AnyIndicatorMeta) -> some View {
        Button {
            config.add(meta.identifier)
            showAddPopover = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(meta.identifier)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
    }

    // MARK: - Sections

    private func section(label: String,
                          items: [IndicatorInstance]) -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            VStack(spacing: 10) {
                ForEach(items) { inst in
                    IndicatorCard(instance: inst, config: config)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text("No indicators yet")
                .font(.system(size: 15, weight: .semibold))
            Text("Add SMA, EMA, MACD, RSI, Bollinger Bands, KDJ — anything from the indicator catalogue. Per-chart settings are global, so what you set up here applies to every ticker.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Button { showAddPopover = true } label: {
                Label("Pick from catalogue", systemImage: "plus")
            }
            .buttonStyle(LiquidGlassButtonStyle(prominent: true))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Indicator card

/// One Liquid Glass card per indicator instance. Top row = identity
/// (color chip + name + delete). Bottom row = parameter tags rendered
/// as inline pills.
private struct IndicatorCard: View {

    let instance: IndicatorInstance
    @Bindable var config: ChartIndicatorConfig
    @Environment(\.chartTheme) private var theme

    private var meta: AnyIndicatorMeta? {
        IndicatorRegistry.shared.find(instance.identifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                colorChip
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta?.displayName ?? instance.identifier)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(instance.identifier)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    config.remove(id: instance.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove indicator")
            }
            if let meta, !meta.parameters.isEmpty {
                paramTags(meta: meta)
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 12,
                     tint: theme.indicatorColor(instance.paletteSlot)
                            .opacity(0.05))
    }

    /// Cycles through the eight indicator palette slots. The popover
    /// shows all eight as a row so the user picks visually rather
    /// than clicking-to-discover.
    @State private var showColorPopover: Bool = false
    private var colorChip: some View {
        Button {
            showColorPopover.toggle()
        } label: {
            Circle()
                .fill(theme.indicatorColor(instance.paletteSlot))
                .frame(width: 18, height: 18)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: theme.indicatorColor(instance.paletteSlot)
                                .opacity(0.5),
                        radius: 4)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showColorPopover, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                ForEach(0..<theme.indicatorPalette.count, id: \.self) { slot in
                    Button {
                        config.updatePaletteSlot(id: instance.id, slot: slot)
                        showColorPopover = false
                    } label: {
                        Circle()
                            .fill(theme.indicatorColor(slot))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        slot == instance.paletteSlot
                                        ? Color.white.opacity(0.9)
                                        : Color.white.opacity(0.18),
                                        lineWidth: slot == instance.paletteSlot
                                                   ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }

    // MARK: Parameter tags

    private func paramTags(meta: AnyIndicatorMeta) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(meta.parameters, id: \.name) { p in
                parameterTag(for: p)
            }
        }
    }

    @ViewBuilder
    private func parameterTag(for p: IndicatorParameter) -> some View {
        switch p {
        case .int(let ip):
            ParamTag(
                label: ip.name.capitalized,
                value: "\(currentInt(name: ip.name, fallback: ip.default))",
                onMinus: {
                    let v = currentInt(name: ip.name, fallback: ip.default)
                    setInt(name: ip.name,
                           value: max(ip.min, v - step(ip.min, ip.max)))
                },
                onPlus: {
                    let v = currentInt(name: ip.name, fallback: ip.default)
                    setInt(name: ip.name,
                           value: min(ip.max, v + step(ip.min, ip.max)))
                }
            )

        case .double(let dp):
            ParamTag(
                label: dp.name.capitalized,
                value: String(format: "%.2f",
                              currentDouble(name: dp.name,
                                             fallback: dp.default)),
                onMinus: {
                    let v = currentDouble(name: dp.name,
                                           fallback: dp.default)
                    setDouble(name: dp.name,
                              value: max(dp.min, v - 0.1))
                },
                onPlus: {
                    let v = currentDouble(name: dp.name,
                                           fallback: dp.default)
                    setDouble(name: dp.name,
                              value: min(dp.max, v + 0.1))
                }
            )

        case .bool, .color:
            EmptyView()
        }
    }

    // Use a step proportional to the int range so big-ranged
    // parameters (e.g. 1...500 period) aren't tediously +1/-1.
    private func step(_ lo: Int, _ hi: Int) -> Int {
        let span = hi - lo
        if span <= 30   { return 1 }
        if span <= 100  { return 2 }
        if span <= 300  { return 5 }
        return 10
    }

    private func currentInt(name: String, fallback: Int) -> Int {
        if case .int(let v) = instance.arguments[name] { return v }
        return fallback
    }
    private func currentDouble(name: String, fallback: Double) -> Double {
        if case .double(let v) = instance.arguments[name] { return v }
        if case .int(let v)    = instance.arguments[name] { return Double(v) }
        return fallback
    }
    private func setInt(name: String, value: Int) {
        config.updateArguments(id: instance.id) { $0[name] = .int(value) }
    }
    private func setDouble(name: String, value: Double) {
        config.updateArguments(id: instance.id) { $0[name] = .double(value) }
    }
}

// MARK: - Param tag (label · value · ± stepper)

private struct ParamTag: View {
    let label: String
    let value: String
    let onMinus: () -> Void
    let onPlus:  () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .semibold,
                              design: .monospaced))
                .foregroundStyle(.primary)
            HStack(spacing: 1) {
                Button(action: onMinus) {
                    Image(systemName: "minus")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button(action: onPlus) {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.secondary.opacity(0.10))
        )
        .overlay(
            Capsule().strokeBorder(Color.secondary.opacity(0.18),
                                   lineWidth: 0.5)
        )
    }
}

// MARK: - Flow layout (wraps tags to next line)

/// Minimal flow layout — left-to-right, top-to-bottom, wraps when
/// the next item won't fit on the current row. Avoids pulling in
/// `swift-algorithms` / a third-party flow layout package for one
/// caller.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout Void) -> CGSize
    {
        let width = proposal.width ?? .infinity
        let rows = rowsFor(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height + spacing } - spacing
        return CGSize(width: width, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout Void)
    {
        let width = bounds.width
        let rows = rowsFor(subviews: subviews, width: width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for idx in row.indices {
                let sv = subviews[idx]
                let size = sv.sizeThatFits(.unspecified)
                sv.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func rowsFor(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        var x: CGFloat = 0
        for (i, sv) in subviews.enumerated() {
            let size = sv.sizeThatFits(.unspecified)
            let needed = x == 0 ? size.width : x + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
                x = 0
            }
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height,
                                              size.height)
            x = (x == 0) ? size.width : x + spacing + size.width
        }
        return rows
    }
}

// MARK: - IndicatorCategory display

private extension IndicatorCategory {
    var label: String {
        switch self {
        case .trend:             return "Trend"
        case .momentum:          return "Momentum"
        case .volatility:        return "Volatility"
        case .volume:            return "Volume"
        case .supportResistance: return "Support / Resistance"
        }
    }
}
