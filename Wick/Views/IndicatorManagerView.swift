import SwiftUI
import CoreCharts
import IndicatorKit

// MARK: - Indicator manager (sheet on the chart's "Indicators" button)

/// Cleaner pass on the indicator config sheet. Reads bottom-up like an
/// Apple system pane:
///
///   ┌── Indicators ──────────────────────────  [Add]  [×] ┐
///   │  2 active · drag to reorder                          │
///   ├──────────────────────────────────────────────────────┤
///   │  On price                                            │
///   │   ▸  ● SMA(20)              period 20      🗑        │
///   │   ▾  ● EMA(50)              period 50      🗑        │
///   │        [period   −  50  +]                           │
///   │                                                      │
///   │  Below the chart                                     │
///   │   ▸  ● MACD(12,26,9)                       🗑        │
///   └──────────────────────────────────────────────────────┘
///
/// Visual changes vs. the prior design:
/// - All sizing via system semantic fonts (Dynamic Type flows through).
/// - Rows are flat surfaces, not nested glass cards. The drill-in
///   chevron expands inline parameter editors only when the user
///   asks for them — avoids the previous "every param pill always
///   on screen" wall of micro-typography.
/// - One label per row (`displayName(args)`) instead of name + raw
///   identifier double-labeling.
/// - Bigger tap targets on +/− (28pt) and trash (28pt).
struct IndicatorManagerView: View {

    @Bindable var config: ChartIndicatorConfig

    /// True when hosted as a modal sheet — renders a close button. The
    /// chart-header "Indicators" button always presents as a sheet
    /// (the embedded-in-Settings surface was removed).
    var presentedAsSheet: Bool = true

    @Environment(\.dismiss) private var dismiss
    @State private var showAddPopover: Bool = false
    @State private var expandedRows: Set<UUID> = []

    /// Group indicators by where they render so pane real-estate reads
    /// at a glance.
    private var groupedInstances: [(label: String, items: [IndicatorInstance])] {
        let main   = config.instances.filter { $0.paneID == .main }
        let volume = config.instances.filter {
            if case .volume = $0.paneID { return true } else { return false }
        }
        let subs   = config.instances.filter {
            if case .sub = $0.paneID { return true } else { return false }
        }
        var out: [(String, [IndicatorInstance])] = []
        if !main.isEmpty   { out.append(("On price", main)) }
        if !volume.isEmpty { out.append(("On volume", volume)) }
        if !subs.isEmpty   { out.append(("Below the chart", subs)) }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
                .padding(.vertical, 20)
            }
        }
        .frame(minWidth: 520, minHeight: 540)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Indicators")
                    .font(.title2.weight(.semibold))
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            addButton
            if presentedAsSheet {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("IndicatorManagerClose")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, presentedAsSheet ? 18 : 6)
        .padding(.bottom, 14)
    }

    private var headerSubtitle: String {
        let n = config.instances.count
        switch n {
        case 0: return "Nothing pinned yet"
        case 1: return "1 active"
        default: return "\(n) active"
        }
    }

    // MARK: - Add catalogue

    private var addButton: some View {
        Button {
            showAddPopover.toggle()
        } label: {
            Label("Add", systemImage: "plus")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .popover(isPresented: $showAddPopover, arrowEdge: .bottom) {
            addCatalogue
                .frame(width: 380, height: 440)
        }
        .accessibilityIdentifier("IndicatorAddButton")
    }

    private var addCatalogue: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Indicator catalogue")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(IndicatorCategory.allCases, id: \.self) { cat in
                        let items = IndicatorRegistry.shared.indicators(category: cat)
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(cat.label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                VStack(spacing: 4) {
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
    }

    private func catalogueRow(_ meta: AnyIndicatorMeta) -> some View {
        Button {
            config.add(meta.identifier)
            showAddPopover = false
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                Text(meta.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.headline)
                Text("\(items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.bottom, 2)
            VStack(spacing: 1) {
                ForEach(items) { inst in
                    IndicatorRow(
                        instance: inst,
                        config: config,
                        expanded: Binding(
                            get: { expandedRows.contains(inst.id) },
                            set: { isOn in
                                if isOn { expandedRows.insert(inst.id) }
                                else    { expandedRows.remove(inst.id) }
                            }))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text("No indicators yet")
                .font(.title3.weight(.semibold))
            Text("Add an indicator from the catalogue — SMA, EMA, MACD, RSI, Bollinger Bands, KDJ, and more. Your selection applies to every ticker's chart.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
            Button { showAddPopover = true } label: {
                Label("Pick from catalogue", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

// MARK: - Row

/// One indicator entry. Collapsed: drag chevron, color disc, name +
/// param summary, trash. Expanded: inline parameter editors below.
private struct IndicatorRow: View {

    let instance: IndicatorInstance
    @Bindable var config: ChartIndicatorConfig
    @Binding var expanded: Bool

    @Environment(\.chartTheme) private var theme

    private var meta: AnyIndicatorMeta? {
        IndicatorRegistry.shared.find(instance.identifier)
    }

    /// "SMA(20)" / "MACD(12,26,9)" — one-line view of the instance's
    /// current param values. Identifier is hidden — the display name
    /// is enough.
    private var headerTitle: String {
        let base = meta?.displayName ?? instance.identifier
        let summary = paramSummary
        return summary.isEmpty ? base : "\(base) (\(summary))"
    }

    private var paramSummary: String {
        guard let meta else { return "" }
        return meta.parameters.compactMap { p -> String? in
            switch p {
            case .int(let ip):
                let v: Int
                if case .int(let stored) = instance.arguments[ip.name] {
                    v = stored
                } else { v = ip.default }
                return "\(v)"
            case .double(let dp):
                let v: Double
                if case .double(let stored) = instance.arguments[dp.name] {
                    v = stored
                } else if case .int(let stored) = instance.arguments[dp.name] {
                    v = Double(stored)
                } else { v = dp.default }
                return String(format: "%.1f", v)
            case .bool, .color:
                return nil
            }
        }.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 0) {
            row
            if expanded, let meta, !meta.parameters.isEmpty {
                Divider().opacity(0.4)
                parameterEditors(meta: meta)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.18), value: expanded)
    }

    @ViewBuilder
    private var row: some View {
        HStack(spacing: 12) {
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(meta?.parameters.isEmpty ?? true)
            .opacity((meta?.parameters.isEmpty ?? true) ? 0.0 : 1.0)
            .accessibilityHidden(true)

            colorChip

            Text(headerTitle)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .onTapGesture { expanded.toggle() }

            Spacer()

            Button {
                config.remove(id: instance.id)
            } label: {
                Image(systemName: "trash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove indicator")
            .accessibilityLabel("Remove indicator")
            .accessibilityIdentifier("IndicatorRemove-\(instance.id)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: Color picker

    @State private var showColorPopover: Bool = false

    private var colorChip: some View {
        Button {
            showColorPopover.toggle()
        } label: {
            Circle()
                .fill(theme.indicatorColor(instance.paletteSlot))
                .frame(width: 14, height: 14)
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.12),
                                       lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .help("Change colour")
        .accessibilityLabel("Indicator colour")
        .popover(isPresented: $showColorPopover, arrowEdge: .bottom) {
            colorPalette
                .padding(14)
        }
    }

    private var colorPalette: some View {
        HStack(spacing: 10) {
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
                                    ? Color.primary
                                    : Color.primary.opacity(0.12),
                                    lineWidth: slot == instance.paletteSlot ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour slot \(slot + 1)")
            }
        }
    }

    // MARK: Parameter editors

    @ViewBuilder
    private func parameterEditors(meta: AnyIndicatorMeta) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(meta.parameters, id: \.name) { p in
                parameterRow(for: p)
            }
        }
    }

    @ViewBuilder
    private func parameterRow(for p: IndicatorParameter) -> some View {
        switch p {
        case .int(let ip):
            ParameterStepper(
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
                },
                minDisabled: currentInt(name: ip.name, fallback: ip.default) <= ip.min,
                maxDisabled: currentInt(name: ip.name, fallback: ip.default) >= ip.max)

        case .double(let dp):
            ParameterStepper(
                label: dp.name.capitalized,
                value: String(format: "%.2f",
                              currentDouble(name: dp.name, fallback: dp.default)),
                onMinus: {
                    let v = currentDouble(name: dp.name, fallback: dp.default)
                    setDouble(name: dp.name, value: max(dp.min, v - 0.1))
                },
                onPlus: {
                    let v = currentDouble(name: dp.name, fallback: dp.default)
                    setDouble(name: dp.name, value: min(dp.max, v + 0.1))
                },
                minDisabled: currentDouble(name: dp.name, fallback: dp.default) <= dp.min,
                maxDisabled: currentDouble(name: dp.name, fallback: dp.default) >= dp.max)

        case .bool, .color:
            EmptyView()
        }
    }

    /// Bigger step for parameters with wider ranges so the user isn't
    /// stuck +1/-1 through 500.
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

// MARK: - Parameter stepper row

/// Clean label + value + −/+ row. Symbols are full-sized control
/// targets (28pt), value reads in monospaced digits for stability.
private struct ParameterStepper: View {
    let label: String
    let value: String
    let onMinus: () -> Void
    let onPlus:  () -> Void
    var minDisabled: Bool = false
    var maxDisabled: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button(action: onMinus) {
                    Image(systemName: "minus")
                        .font(.callout.weight(.semibold))
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(minDisabled)
                .accessibilityLabel("Decrease \(label)")
                Text(value)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .frame(minWidth: 56)
                Button(action: onPlus) {
                    Image(systemName: "plus")
                        .font(.callout.weight(.semibold))
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(maxDisabled)
                .accessibilityLabel("Increase \(label)")
            }
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
        }
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
