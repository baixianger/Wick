import Foundation
import SwiftUI

enum HoldingSide: String, Codable, Hashable {
    case buy
    case sell

    var label: String { self == .buy ? "Buy" : "Sell" }
    var sign: Double  { self == .buy ?  1 : -1 }
}

/// Where a `Holding` came from. `.manual` is anything typed into the
/// Holdings editor; `.imported` carries the originating broker name and
/// document title so the user can audit which file produced which row.
enum HoldingSource: Hashable {
    case manual
    case imported(broker: String, document: String)
}

extension HoldingSource: Codable {
    private enum CodingKeys: String, CodingKey { case kind, broker, document }
    private enum Kind: String, Codable { case manual, imported }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .manual:
            self = .manual
        case .imported:
            let broker = try c.decode(String.self, forKey: .broker)
            let document = try c.decode(String.self, forKey: .document)
            self = .imported(broker: broker, document: document)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try c.encode(Kind.manual, forKey: .kind)
        case .imported(let broker, let document):
            try c.encode(Kind.imported, forKey: .kind)
            try c.encode(broker, forKey: .broker)
            try c.encode(document, forKey: .document)
        }
    }
}

struct Holding: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var symbol: String
    var name: String
    var side: HoldingSide
    var date: Date
    var quantity: Double
    var price: Double
    var currency: String
    /// Broker-assigned trade identifier when known. Primary dedup key on
    /// re-import: if the same `externalId` already exists, the incoming
    /// row is treated as a duplicate.
    var externalId: String?
    /// Provenance. Defaults to `.manual` so rows written before this
    /// field existed decode without losing data.
    var source: HoldingSource

    init(id: UUID = UUID(),
         symbol: String,
         name: String,
         side: HoldingSide,
         date: Date,
         quantity: Double,
         price: Double,
         currency: String,
         externalId: String? = nil,
         source: HoldingSource = .manual) {
        self.id = id
        self.symbol = symbol
        self.name = name
        self.side = side
        self.date = date
        self.quantity = quantity
        self.price = price
        self.currency = currency
        self.externalId = externalId
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, symbol, name, side, date, quantity, price, currency
        case externalId, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.symbol = try c.decode(String.self, forKey: .symbol)
        self.name = try c.decode(String.self, forKey: .name)
        self.side = try c.decode(HoldingSide.self, forKey: .side)
        self.date = try c.decode(Date.self, forKey: .date)
        self.quantity = try c.decode(Double.self, forKey: .quantity)
        self.price = try c.decode(Double.self, forKey: .price)
        self.currency = try c.decode(String.self, forKey: .currency)
        self.externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        self.source = try c.decodeIfPresent(HoldingSource.self, forKey: .source) ?? .manual
    }

    var signedQuantity: Double { side.sign * quantity }
}

@MainActor
@Observable
final class HoldingsStore {

    var holdings: [Holding] {
        didSet { save() }
    }

    private let defaultsKey = "candlekit.holdings.v1"
    /// One-shot migration flag. When false, every previously auto-seeded
    /// row (legacy 2024 fakes + v2/v3 real-price sample rows) is removed
    /// so existing installs go back to an empty portfolio. Anything the
    /// user typed in by hand survives. The seed itself is gone — sample
    /// data is now opt-in via `loadSampleTransactions()`.
    private let migrationKey = "candlekit.holdings.migrate.v4-empty"

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([Holding].self, from: data) {
            self.holdings = decoded
        } else {
            self.holdings = []
        }
        migrateClearAutoSeededRowsIfNeeded()
    }

    /// First-launch-after-upgrade pass. Drops any (symbol, day) pair that
    /// was once injected by an old auto-seed; leaves user-entered rows
    /// (any other date) untouched. Idempotent via `migrationKey`.
    private func migrateClearAutoSeededRowsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }
        let known = Self.autoSeedDateKeys
        let dayKey: (Holding) -> String = { h in
            let cal = Calendar(identifier: .gregorian)
            let c = cal.dateComponents([.year, .month, .day], from: h.date)
            return "\(h.symbol)|\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        }
        let before = holdings.count
        holdings.removeAll { known.contains(dayKey($0)) }
        let removed = before - holdings.count
        defaults.set(true, forKey: migrationKey)
        if removed > 0 { save() }
    }

    /// Opt-in: load a deterministic sample portfolio covering AAPL /
    /// MSFT / NVDA / TSLA / GOOGL / META so the user can see how the
    /// Portfolio page behaves without typing twelve transactions by
    /// hand. Surfaced behind a button on the empty-state. Every `price`
    /// is a real Yahoo daily close for that symbol on that date, so the
    /// markers line up exactly on the Overview area chart.
    func loadSampleTransactions() {
        holdings.append(contentsOf: Self.sampleTransactions())
    }

    private static func sampleTransactions() -> [Holding] {
        let cal = Calendar(identifier: .gregorian)
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: day)) ?? Date()
        }
        return [
            // AAPL
            Holding(symbol: "AAPL", name: "Apple Inc.",
                    side: .buy,  date: d(2025, 8, 15),
                    quantity: 30, price: 231.59, currency: "USD"),
            Holding(symbol: "AAPL", name: "Apple Inc.",
                    side: .buy,  date: d(2026, 1, 12),
                    quantity: 20, price: 260.25, currency: "USD"),
            Holding(symbol: "AAPL", name: "Apple Inc.",
                    side: .buy,  date: d(2026, 3, 10),
                    quantity: 15, price: 260.83, currency: "USD"),
            Holding(symbol: "AAPL", name: "Apple Inc.",
                    side: .sell, date: d(2026, 5, 5),
                    quantity: 8,  price: 284.18, currency: "USD"),

            // MSFT
            Holding(symbol: "MSFT", name: "Microsoft Corporation",
                    side: .buy,  date: d(2025, 6, 20),
                    quantity: 20, price: 477.40, currency: "USD"),
            Holding(symbol: "MSFT", name: "Microsoft Corporation",
                    side: .sell, date: d(2025, 11, 10),
                    quantity: 5,  price: 506.00, currency: "USD"),
            Holding(symbol: "MSFT", name: "Microsoft Corporation",
                    side: .buy,  date: d(2026, 4, 15),
                    quantity: 12, price: 411.22, currency: "USD"),

            // NVDA
            Holding(symbol: "NVDA", name: "NVIDIA Corporation",
                    side: .buy,  date: d(2024, 12, 5),
                    quantity: 25, price: 145.06, currency: "USD"),
            Holding(symbol: "NVDA", name: "NVIDIA Corporation",
                    side: .sell, date: d(2025, 9, 22),
                    quantity: 10, price: 183.61, currency: "USD"),
            Holding(symbol: "NVDA", name: "NVIDIA Corporation",
                    side: .buy,  date: d(2026, 4, 2),
                    quantity: 20, price: 177.39, currency: "USD"),
            Holding(symbol: "NVDA", name: "NVIDIA Corporation",
                    side: .sell, date: d(2026, 5, 12),
                    quantity: 10, price: 220.78, currency: "USD"),

            // TSLA
            Holding(symbol: "TSLA", name: "Tesla, Inc.",
                    side: .buy,  date: d(2025, 7, 8),
                    quantity: 15, price: 297.81, currency: "USD"),
            Holding(symbol: "TSLA", name: "Tesla, Inc.",
                    side: .sell, date: d(2025, 11, 10),
                    quantity: 6,  price: 445.23, currency: "USD"),
            Holding(symbol: "TSLA", name: "Tesla, Inc.",
                    side: .buy,  date: d(2026, 5, 15),
                    quantity: 10, price: 422.24, currency: "USD"),

            // GOOGL
            Holding(symbol: "GOOGL", name: "Alphabet Inc.",
                    side: .buy,  date: d(2025, 7, 8),
                    quantity: 25, price: 174.36, currency: "USD"),
            Holding(symbol: "GOOGL", name: "Alphabet Inc.",
                    side: .sell, date: d(2025, 10, 15),
                    quantity: 10, price: 251.03, currency: "USD"),
            Holding(symbol: "GOOGL", name: "Alphabet Inc.",
                    side: .buy,  date: d(2026, 4, 20),
                    quantity: 25, price: 337.42, currency: "USD"),

            // META
            Holding(symbol: "META", name: "Meta Platforms",
                    side: .buy,  date: d(2025, 8, 20),
                    quantity: 8,  price: 747.72, currency: "USD"),
        ]
    }

    /// Every (symbol, day) ever shipped as part of an auto-seed across
    /// any prior version. The migration in `init` uses this to wipe
    /// previously-auto-seeded rows from existing installs so they end
    /// up with an empty portfolio. User-entered rows (any other date)
    /// survive untouched.
    nonisolated static let autoSeedDateKeys: Set<String> = [
        // legacy v1 fakes (2024)
        "AAPL|2024-1-15",  "AAPL|2024-9-10",
        "MSFT|2024-3-20",
        "NVDA|2024-5-12",  "NVDA|2024-11-8",
        "TSLA|2024-7-22",
        "GOOGL|2024-2-5",
        // legacy v2 real (2026)
        "AAPL|2026-3-10",  "AAPL|2026-5-5",
        "NVDA|2026-4-2",   "NVDA|2026-5-12",
        "MSFT|2026-4-15",
        "TSLA|2026-5-15",
        "GOOGL|2026-4-20",
        // v3 additions (2024–2025 real)
        "AAPL|2025-8-15",  "AAPL|2026-1-12",
        "MSFT|2025-6-20",  "MSFT|2025-11-10",
        "NVDA|2024-12-5",  "NVDA|2025-9-22",
        "TSLA|2025-7-8",   "TSLA|2025-11-10",
        "GOOGL|2025-7-8",  "GOOGL|2025-10-15",
        "META|2025-8-20",
    ]

    func add(_ holding: Holding) {
        holdings.append(holding)
    }

    func update(_ holding: Holding) {
        guard let idx = holdings.firstIndex(where: { $0.id == holding.id }) else { return }
        holdings[idx] = holding
    }

    func remove(id: UUID) {
        holdings.removeAll { $0.id == id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(holdings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    func transactions(for symbol: String) -> [Holding] {
        holdings.filter { $0.symbol == symbol }
                .sorted { $0.date < $1.date }
    }

    func positions() -> [SymbolPosition] {
        let grouped = Dictionary(grouping: holdings, by: \.symbol)
        return grouped.compactMap { (_, txs) -> SymbolPosition? in
            guard let any = txs.first else { return nil }
            let buys  = txs.filter { $0.side == .buy }
            let sells = txs.filter { $0.side == .sell }
            let buyQty  = buys.reduce(0)  { $0 + $1.quantity }
            let sellQty = sells.reduce(0) { $0 + $1.quantity }
            let net = buyQty - sellQty
            let avgBuy: Double = {
                guard buyQty > 0 else { return 0 }
                let weighted = buys.reduce(0) { $0 + $1.quantity * $1.price }
                return weighted / buyQty
            }()
            return SymbolPosition(
                symbol: any.symbol,
                name: any.name,
                netQuantity: net,
                averageBuyPrice: avgBuy,
                buyQuantity: buyQty,
                sellQuantity: sellQty,
                currency: any.currency,
                transactionCount: txs.count)
        }
        .sorted { $0.symbol < $1.symbol }
    }
}

// MARK: - Document import

/// Payload returned by a `DocumentImporter`. Mirrors `Holding` minus
/// the database-level fields (`id`, `source`) which the store fills in.
struct ImportedTransaction: Hashable {
    var externalId: String?
    var symbol: String
    var name: String
    var side: HoldingSide
    var date: Date
    var quantity: Double
    var price: Double
    var currency: String
}

/// Outcome of `HoldingsStore.importBatch`. `added` are the rows that
/// were actually written; `skipped` are duplicates that the store
/// refused to insert again.
struct ImportReport: Hashable {
    var added: [Holding]
    var skipped: [SkippedTransaction]
    var broker: String
    var document: String

    var newCount: Int { added.count }
    var skippedCount: Int { skipped.count }
}

struct SkippedTransaction: Hashable {
    enum Reason: String, Hashable {
        /// Incoming `externalId` matched an existing row's `externalId`.
        case externalIdMatch
        /// Incoming row had no `externalId`, but the composite key
        /// (symbol+day+side+qty+price) matched an existing row.
        case fuzzyMatch
    }
    var incoming: ImportedTransaction
    var existing: Holding
    var reason: Reason
}

/// One row in an import preview. Either the transaction is new and
/// will be inserted, or it's a duplicate of `existing` (and the sheet
/// can show the user why).
struct DedupPreview: Hashable, Identifiable {
    var id = UUID()
    var transaction: ImportedTransaction
    var existing: Holding?
    var reason: SkippedTransaction.Reason?

    var isDuplicate: Bool { existing != nil }
}

@MainActor
extension HoldingsStore {
    /// Insert a batch of transactions extracted from a broker document.
    /// Duplicates are detected primarily by `externalId`. When the
    /// incoming row lacks one, a composite fuzzy key is used as a
    /// fallback so re-imports of statements that don't expose Trade IDs
    /// still don't double-count rows.
    func importBatch(_ batch: [ImportedTransaction],
                     broker: String,
                     document: String) -> ImportReport {
        var working = holdings
        var byExternalId: [String: Holding] = [:]
        for h in working {
            if let eid = h.externalId { byExternalId[eid] = h }
        }
        var added: [Holding] = []
        var skipped: [SkippedTransaction] = []

        for tx in batch {
            if let (existing, reason) = Self.findDuplicate(of: tx,
                                                          in: working,
                                                          byExternalId: byExternalId)
            {
                skipped.append(SkippedTransaction(incoming: tx, existing: existing, reason: reason))
                continue
            }
            let h = Holding(
                symbol: tx.symbol,
                name: tx.name,
                side: tx.side,
                date: tx.date,
                quantity: tx.quantity,
                price: tx.price,
                currency: tx.currency,
                externalId: tx.externalId,
                source: .imported(broker: broker, document: document)
            )
            added.append(h)
            working.append(h)
            if let eid = h.externalId { byExternalId[eid] = h }
        }

        if !added.isEmpty {
            // Full reassignment so the @Observable setter fires, then
            // call save() explicitly because didSet is unreliable on
            // @Observable-managed properties.
            holdings = working
            save()
        }
        return ImportReport(added: added, skipped: skipped, broker: broker, document: document)
    }

    /// Dry-run dedup against the live holdings, used by the import
    /// sheet to show "new" vs "duplicate" badges per row before the
    /// user commits. The actual `importBatch` re-runs the same logic
    /// at commit time, so the preview is purely informational.
    func previewImport(_ batch: [ImportedTransaction]) -> [DedupPreview] {
        var byExternalId: [String: Holding] = [:]
        for h in holdings {
            if let eid = h.externalId { byExternalId[eid] = h }
        }
        return batch.map { tx in
            if let (existing, reason) = Self.findDuplicate(of: tx,
                                                          in: holdings,
                                                          byExternalId: byExternalId)
            {
                return DedupPreview(transaction: tx, existing: existing, reason: reason)
            }
            return DedupPreview(transaction: tx, existing: nil, reason: nil)
        }
    }

    /// Shared dedup. Returns the existing row and the reason if `tx`
    /// matches one; nil if `tx` is genuinely new.
    private static func findDuplicate(of tx: ImportedTransaction,
                                      in existing: [Holding],
                                      byExternalId: [String: Holding])
        -> (Holding, SkippedTransaction.Reason)?
    {
        if let eid = tx.externalId, let h = byExternalId[eid] {
            return (h, .externalIdMatch)
        }
        if let h = existing.first(where: { fuzzyMatches(existing: $0, incoming: tx) }) {
            return (h, .fuzzyMatch)
        }
        return nil
    }

    /// Composite-key fuzzy dedup. Only invoked when the incoming row
    /// has no `externalId` — broker statements that DO include Trade
    /// IDs always go through the exact-match path.
    private static func fuzzyMatches(existing: Holding, incoming: ImportedTransaction) -> Bool {
        guard incoming.externalId == nil else { return false }
        let cal = Calendar(identifier: .gregorian)
        return cal.isDate(existing.date, inSameDayAs: incoming.date)
            && existing.symbol.uppercased() == incoming.symbol.uppercased()
            && existing.side == incoming.side
            && abs(existing.quantity - incoming.quantity) < 0.0001
            && abs(existing.price - incoming.price) < 0.01
    }
}

struct SymbolPosition: Identifiable, Hashable {
    let symbol: String
    let name: String
    let netQuantity: Double
    let averageBuyPrice: Double
    let buyQuantity: Double
    let sellQuantity: Double
    let currency: String
    let transactionCount: Int

    var id: String { symbol }
    var isShort: Bool { netQuantity < 0 }
}
