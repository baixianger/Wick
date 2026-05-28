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
            let symbols = Set(holdings.map(\.symbol))
            return all.filter { symbols.contains($0.symbol) }
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
