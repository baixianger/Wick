import SwiftUI
import CoreCharts
import IndicatorKit

// MARK: - Per-indicator pane traits

/// Display-only metadata for an indicator-driven sub-pane: just the
/// dashed reference levels (RSI 30 / 70, KDJ 20 / 80, MACD 0). Keyed by
/// indicator `identifier` because this is presentation knowledge — the
/// `IndicatorRegistry` deliberately ships compute metadata only. No
/// "overbought / oversold" gradient zones: the colored fills competed
/// visually with the K-line and the user explicitly asked them gone.
struct IndicatorPaneTrait {
    var referenceLevels: [Double] = []

    static func trait(for identifier: String) -> IndicatorPaneTrait {
        switch identifier {
        case "macd":       return IndicatorPaneTrait(referenceLevels: [0])
        case "kdj":        return IndicatorPaneTrait(referenceLevels: [20, 80])
        case "rsi":        return IndicatorPaneTrait(referenceLevels: [30, 70])
        case "stochastic": return IndicatorPaneTrait(referenceLevels: [20, 80])
        default:           return IndicatorPaneTrait()
        }
    }
}

// MARK: - Indicator argument helpers

/// Pull a sensible default-argument bag out of an indicator's parameter
/// schema. Lets `IndicatorConfig.add(_:)` create new instances with the
/// indicator's own defaults instead of hand-rolling them per type.
private func defaultArguments(for meta: AnyIndicatorMeta)
    -> [String: IndicatorInstance.ArgumentValue]
{
    var args: [String: IndicatorInstance.ArgumentValue] = [:]
    for p in meta.parameters {
        switch p {
        case .int(let ip):    args[ip.name] = .int(ip.default)
        case .double(let dp): args[dp.name] = .double(dp.default)
        case .bool(let bp):   args[bp.name] = .bool(bp.default)
        case .color:
            // Color is driven by `paletteSlot`, not an argument.
            continue
        }
    }
    return args
}

// MARK: - Title builder

/// Human-readable pane caption built from the indicators sitting on that
/// pane. Single indicator → "MACD (12,26,9)"; multiple on the same pane
/// → comma-joined ("MACD (12,26,9), KDJ (9,3,3)"). Empty pane → nil.
private func paneTitle(for instances: [IndicatorInstance]) -> String? {
    let parts = instances.compactMap { inst -> String? in
        guard let meta = IndicatorRegistry.shared.find(inst.identifier) else {
            return nil
        }
        let intArgs = meta.parameters.compactMap { p -> Int? in
            if case .int(let ip) = p {
                if case .int(let v) = inst.arguments[ip.name] { return v }
                return ip.default
            }
            return nil
        }
        if intArgs.isEmpty {
            return meta.displayName
        }
        let joined = intArgs.map(String.init).joined(separator: ",")
        return "\(meta.displayName) (\(joined))"
    }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
}

// MARK: - ChartIndicatorConfig

/// Source of truth for the Chart tab's indicator list. Drives both
/// `coordinator.indicators` and the derived `coordinator.panes`. Single
/// instance lives in ContentView and survives ticker / scale switches —
/// "全局共用" per the spec.
@MainActor
@Observable
final class ChartIndicatorConfig {

    var instances: [IndicatorInstance]

    init(instances: [IndicatorInstance] = ChartIndicatorConfig.defaultInstances) {
        self.instances = instances
    }

    /// Matches the previous hardcoded `setupIndicators` so first-run users
    /// see the same K + SMA(5/10/20) + MACD + KDJ + RSI panel they had
    /// before the indicator manager existed. `nonisolated` so it can be
    /// referenced from `init`'s default-arg expression (the class is
    /// `@MainActor`; the constant is `Sendable` so `nonisolated` alone
    /// is enough — no `(unsafe)` opt-out needed).
    nonisolated static let defaultInstances: [IndicatorInstance] = [
        IndicatorInstance(identifier: "sma", paneID: .main, paletteSlot: 0,
                          arguments: ["period": .int(5)]),
        IndicatorInstance(identifier: "sma", paneID: .main, paletteSlot: 1,
                          arguments: ["period": .int(10)]),
        IndicatorInstance(identifier: "sma", paneID: .main, paletteSlot: 2,
                          arguments: ["period": .int(20)]),
        IndicatorInstance(identifier: "macd", paneID: .sub("macd"), paletteSlot: 0),
        IndicatorInstance(identifier: "kdj",  paneID: .sub("kdj"),  paletteSlot: 0),
        IndicatorInstance(identifier: "rsi",  paneID: .sub("rsi"),  paletteSlot: 1,
                          arguments: ["period": .int(14)]),
    ]

    // MARK: - Derived structure

    /// Pane specs derived from the instance list. Always main + volume,
    /// then one sub-pane per unique sub paneID in the order it first
    /// appears in `instances`. Used by `ChartTabState.setupPanes`.
    var derivedPanes: [PaneSpec] {
        var panes: [PaneSpec] = [
            PaneSpec(id: .main,   heightWeight: 5, title: nil,
                     preferredYTickCount: 6),
            PaneSpec(id: .volume, heightWeight: 1, title: "Volume",
                     preferredYTickCount: 0),
        ]
        var seen = Set<PaneID>()
        var order: [PaneID] = []
        for inst in instances {
            if case .sub = inst.paneID, !seen.contains(inst.paneID) {
                seen.insert(inst.paneID)
                order.append(inst.paneID)
            }
        }
        for paneID in order {
            let inPane = instances.filter { $0.paneID == paneID }
            // Trait from the first indicator's identifier; user can stack
            // multiple indicators on one pane but reference lines / zones
            // follow the pane's "primary" indicator.
            let primary = inPane.first?.identifier ?? ""
            let trait = IndicatorPaneTrait.trait(for: primary)
            panes.append(PaneSpec(
                id: paneID,
                heightWeight: 1.6,
                title: paneTitle(for: inPane),
                preferredYTickCount: 0,
                referenceLevels: trait.referenceLevels))
        }
        return panes
    }

    // MARK: - Mutations

    /// Add an indicator of type `identifier` with its default arguments.
    /// Overlay indicators land on `.main`; sub-pane indicators land on
    /// `.sub(identifier)` — stacking on the existing pane of the same
    /// type if one already exists.
    func add(_ identifier: String) {
        guard let meta = IndicatorRegistry.shared.find(identifier) else { return }
        let paneID: PaneID = meta.placement == .subPane
            ? .sub(identifier)
            : .main
        // Allocate the next palette slot deterministically. Caps wrap at
        // 8 (ChartTheme palette length).
        let nextSlot = (instances.last?.paletteSlot ?? -1) + 1
        let inst = IndicatorInstance(
            identifier: identifier,
            paneID: paneID,
            paletteSlot: max(0, nextSlot % 8),
            arguments: defaultArguments(for: meta))
        instances.append(inst)
    }

    func remove(id: IndicatorInstance.ID) {
        instances.removeAll { $0.id == id }
    }

    /// Drag-reorder hook for SwiftUI List/.onMove. Indices refer to the
    /// flat `instances` array; sub-pane order is whatever falls out of
    /// the new "first appearance" walk.
    func move(from source: IndexSet, to destination: Int) {
        instances.move(fromOffsets: source, toOffset: destination)
    }

    /// Replace one instance's arguments — used by the inline parameter
    /// editor when the user changes a Stepper or Slider value.
    func updateArguments(id: IndicatorInstance.ID,
                         _ mutate: (inout [String: IndicatorInstance.ArgumentValue]) -> Void)
    {
        guard let idx = instances.firstIndex(where: { $0.id == id }) else { return }
        var args = instances[idx].arguments
        mutate(&args)
        instances[idx].arguments = args
    }

    /// Palette-slot cycle for the row-level color chip.
    func updatePaletteSlot(id: IndicatorInstance.ID, slot: Int) {
        guard let idx = instances.firstIndex(where: { $0.id == id }) else { return }
        instances[idx].paletteSlot = slot
    }
}
