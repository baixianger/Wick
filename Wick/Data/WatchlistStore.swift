import Foundation
import SwiftUI
import TradingFloor

struct WatchlistGroup: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var symbols: [String] = []
}

enum WatchlistGroupSelection: Hashable, Codable {
    case all
    case holdings
    case user(UUID)
}

@MainActor
@Observable
final class WatchlistStore {

    /// Watchlist groups are mutated through `_modify` accessors
    /// (`groups.append`, `groups[idx].name = …`, `groups.removeAll`).
    /// The `@Observable` macro's `_modify` accessor doesn't propagate
    /// to a stored-property `didSet`, so every mutation method below
    /// calls `saveGroups()` explicitly. Don't rely on `didSet` here.
    var groups: [WatchlistGroup]
    var selection: WatchlistGroupSelection {
        didSet { saveSelection() }
    }

    private let groupsKey = SharedStore.Keys.watchlist
    private let selectionKey = "candlekit.watchlist.selection.v1"

    init() {
        SharedStore.migrateIfNeeded()
        let defaults = SharedStore.defaults
        if let data = defaults.data(forKey: groupsKey),
           let decoded = try? JSONDecoder().decode([WatchlistGroup].self, from: data) {
            self.groups = decoded
        } else {
            self.groups = []
        }
        if let data = defaults.data(forKey: selectionKey),
           let decoded = try? JSONDecoder().decode(WatchlistGroupSelection.self, from: data) {
            self.selection = decoded
        } else {
            self.selection = .all
        }
    }

    func addGroup(name: String) -> WatchlistGroup {
        let g = WatchlistGroup(name: name)
        groups.append(g)
        saveGroups()
        return g
    }

    func rename(id: UUID, to newName: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].name = newName
        saveGroups()
    }

    func remove(id: UUID) {
        groups.removeAll { $0.id == id }
        if case .user(let sid) = selection, sid == id { selection = .all }
        saveGroups()
    }

    func toggle(symbol: String, in groupId: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        if let symIdx = groups[idx].symbols.firstIndex(of: symbol) {
            groups[idx].symbols.remove(at: symIdx)
        } else {
            groups[idx].symbols.append(symbol)
        }
        saveGroups()
    }

    func filter(tickers all: [Ticker], holdings: [Holding]) -> [Ticker] {
        switch selection {
        case .all:
            return all
        case .holdings:
            // One row per HELD SYMBOL so the Holdings list matches the
            // Portfolio's positions exactly — INCLUDING symbols held but never
            // added to the ticker universe (e.g. a position Wicker recorded, or
            // a CN ticker never searched). The old code did
            // `all.filter { held.contains }`, which silently dropped any held
            // symbol absent from `all` — that was the Holdings↔Portfolio
            // mismatch. Reuse the rich `Ticker` when known; synthesise a minimal
            // surrogate (empty series → LiveDataStore fills it on appear) from
            // the holding's symbol + name otherwise. Sorted by symbol to match
            // `HoldingsStore.positions()` ordering.
            let known = Dictionary(all.map { ($0.symbol, $0) },
                                   uniquingKeysWith: { first, _ in first })
            // Net signed quantity per symbol — `≈ 0` ⇒ fully closed (平仓). The
            // user keeps closed positions visible but wants them sorted to the
            // BOTTOM, so order open (net ≠ 0) first then closed, each by symbol.
            let netBySymbol = Dictionary(grouping: holdings, by: \.symbol)
                .mapValues { $0.reduce(0.0) { $0 + $1.signedQuantity } }
            let isClosed: (String) -> Bool = { abs(netBySymbol[$0] ?? 0) < 1e-9 }
            var seen = Set<String>()
            let uniqueSymbols = holdings.map(\.symbol).filter { seen.insert($0).inserted }
            let ordered = uniqueSymbols.sorted { a, b in
                let ca = isClosed(a), cb = isClosed(b)
                if ca != cb { return !ca }   // open first
                return a < b                 // then alphabetical within each group
            }
            return ordered.map { sym in
                known[sym]
                    ?? Ticker(id: sym, symbol: sym,
                              name: holdings.first { $0.symbol == sym }?.name ?? sym,
                              series: [:])
            }
        case .user(let id):
            guard let group = groups.first(where: { $0.id == id }) else { return all }
            let allowed = Set(group.symbols)
            return all.filter { allowed.contains($0.symbol) }
        }
    }

    private func saveGroups() {
        if let data = try? JSONEncoder().encode(groups) {
            SharedStore.defaults.set(data, forKey: groupsKey)
        }
    }
    private func saveSelection() {
        if let data = try? JSONEncoder().encode(selection) {
            SharedStore.defaults.set(data, forKey: selectionKey)
        }
    }
}
