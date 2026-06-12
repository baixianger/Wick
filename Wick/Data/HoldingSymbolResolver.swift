import Foundation
import CoreCharts
import DataAdapters

/// **Validate-on-failure** resolver for holding symbols (the strategy chosen
/// over "always validate" / "pure mechanical").
///
/// `HoldingsStore` canonicalises symbols mechanically at the entry point
/// (`BrokerSymbol` MIC table + `CNSymbol`). That's fast and offline but blind:
/// an unknown MIC, a provider that uses a different ticker (ADRs, renames,
/// multi-listings), or a typo all produce a string that *looks* canonical yet
/// fetches nothing — a flat row with no 涨跌.
///
/// This resolver closes that gap WITHOUT paying a network round-trip on every
/// add: it watches each held symbol's `LiveDataStore` outcome, and ONLY when a
/// symbol's fetch definitively fails does it ask Yahoo's real search endpoint
/// (`YahooSearchAdapter`) for the authoritative ticker — by company name first
/// (most reliable), then the bare symbol — and rewrites the holding via
/// `HoldingsStore.rename` (which preserves the original string for audit). CN/HK
/// names resolve to `.HK` / `.SS` symbols too, which then route to EastMoney.
///
/// Each symbol is attempted at most once per session (the `attempted` set), so a
/// genuinely-unfetchable symbol doesn't loop.
@MainActor
final class HoldingSymbolResolver {

    private let search = YahooSearchAdapter()
    /// Symbols already run through a resolution attempt this session.
    private var attempted: Set<String> = []

    /// Kick a resolution pass over the current held symbols. Cheap to call on
    /// launch + whenever holdings change — already-attempted symbols are skipped.
    func reconcile(holdings: HoldingsStore, store: LiveDataStore) {
        let bySymbol = Dictionary(grouping: holdings.holdings, by: \.symbol)
        for (symbol, rows) in bySymbol where !attempted.contains(symbol) {
            attempted.insert(symbol)
            let name = rows.first?.name ?? symbol
            Task { [weak holdings] in
                guard let holdings else { return }
                await self.resolveIfFailed(symbol: symbol, name: name,
                                           holdings: holdings, store: store)
            }
        }
    }

    /// Wait for `symbol`'s live fetch to settle; if it FAILED, search for the
    /// real ticker and rename. No-op when the symbol resolved fine.
    private func resolveIfFailed(symbol: String, name: String,
                                 holdings: HoldingsStore, store: LiveDataStore) async {
        guard await waitForFailure(symbol: symbol, store: store) else { return }

        // Search by name first (a clean company name resolves far more reliably
        // than a mangled symbol), then fall back to the bare symbol.
        let bareCode = symbol.split(whereSeparator: { $0 == "." || $0 == ":" }).first.map(String.init) ?? symbol
        for query in [name, symbol, bareCode].filter({ !$0.isEmpty }) {
            guard let results = try? await search.search(query: query),
                  let best = Self.pickBest(results, wantedSymbol: symbol, wantedName: name)
            else { continue }
            if best.symbol.caseInsensitiveCompare(symbol) != .orderedSame {
                holdings.rename(from: symbol, to: best.symbol)
            }
            return   // one successful search settles it (success or same-symbol)
        }
    }

    /// Poll the symbol's `Source` until it's terminal. Returns `true` if the
    /// fetch failed (`.error` / `.unavailable`, or never resolved within the
    /// window — which spans the backoff schedule), `false` if it went `.live`.
    private func waitForFailure(symbol: String, store: LiveDataStore) async -> Bool {
        for _ in 0..<75 {
            switch store.source(for: symbol, interval: .d1) {
            case .live:                 return false
            case .error, .unavailable:  return true
            case .demo, .retrying:      try? await Task.sleep(for: .seconds(1))
            }
        }
        return true
    }

    /// Pick the best search hit: prefer a real equity/ETF, then an exact-ish
    /// symbol or name match, else the top (Yahoo-relevance-ranked) result.
    private static func pickBest(_ results: [YahooSearchResult],
                                 wantedSymbol: String,
                                 wantedName: String) -> YahooSearchResult? {
        guard !results.isEmpty else { return nil }
        let securities = results.filter {
            let t = ($0.quoteType ?? "").uppercased()
            return t == "EQUITY" || t == "ETF" || t.isEmpty
        }
        let pool = securities.isEmpty ? results : securities
        let wantName = wantedName.lowercased()
        // Exact-ish name match wins (handles BE → "Bloom Energy").
        if let named = pool.first(where: {
            $0.displayName.lowercased().contains(wantName) || wantName.contains($0.displayName.lowercased())
        }) { return named }
        return pool.first
    }
}
