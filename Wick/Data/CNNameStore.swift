import Foundation
import Observation
import TradingFloor

/// On-demand cache of EastMoney **Chinese short names** (简称) for A-share /
/// HK tickers — the localized counterpart of `LiveDataStore`'s price cache.
///
/// In Chinese UI mode the ticker-NAME sites want the EastMoney short name
/// (`7666.HK` → "剂泰科技-P", `600519.SS` → "贵州茅台") instead of the
/// broker / English name. `name(for:)` is synchronous: it returns the cached
/// name if present, otherwise (for a CN/HK symbol not already in flight) kicks
/// a background `shortName` fetch and returns `nil`. When the fetch lands it
/// writes the cache; because this is `@Observable`, the rows that read
/// `name(for:)` re-render with the resolved name.
///
/// Best-effort only: US / international symbols never fetch, and any failure
/// leaves the entry absent so callers fall back to the broker name. The fetch
/// uses `push2delay`, a different host from the `push2his` K-line path, so it
/// keeps working during the K-line throttle.
@Observable
@MainActor
final class CNNameStore {

    @ObservationIgnored
    private let provider = EastMoneyExtrasProvider()

    /// symbol → resolved EastMoney short name.
    private var cache: [String: String] = [:]
    /// Symbols with a fetch in progress — guards against duplicate requests
    /// while a row is repeatedly re-evaluated.
    @ObservationIgnored
    private var inFlight: Set<String> = []

    init() {}

    /// Cached EastMoney short name for `symbol`, or `nil` until it loads.
    /// For a CN/HK symbol that isn't cached and isn't already being fetched,
    /// this triggers a background fetch as a side effect.
    func name(for symbol: String) -> String? {
        if let cached = cache[symbol] { return cached }
        guard CNSymbol.parse(symbol) != nil, !inFlight.contains(symbol) else {
            return nil
        }
        inFlight.insert(symbol)
        Task { [provider] in
            let resolved = await provider.shortName(symbol: symbol)
            self.inFlight.remove(symbol)
            if let resolved { self.cache[symbol] = resolved }
        }
        return nil
    }

    /// The name to show for a ticker: in Chinese mode, the EastMoney short
    /// name for a CN/HK symbol when available; otherwise the broker `fallback`
    /// (which is also the English-mode behaviour).
    func displayName(symbol: String, fallback: String, chinese: Bool) -> String {
        guard chinese, CNSymbol.parse(symbol) != nil,
              let name = name(for: symbol)
        else { return fallback }
        return name
    }
}
