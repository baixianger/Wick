import Foundation
import Observation
import CoreCharts
import DataAdapters

/// On-demand wrapper around `YahooFinanceAdapter`. Demo views call
/// `store.series(for:interval:)` synchronously — they get either the
/// cached live series, or the synthetic fallback while a fetch is in
/// flight (and forever if the network never returns). The store mutates
/// its cache when fetches complete; `@Observable` triggers a re-render.
@MainActor
@Observable
final class LiveDataStore {

    enum Source: Equatable {
        case live(fetchedAt: Date)
        case demo                        // never fetched (fallback in use)
        case error(String)               // fetch attempted and failed
    }

    private struct Key: Hashable {
        let symbol: String
        let interval: BarInterval
    }

    @ObservationIgnored
    private let adapter = YahooFinanceAdapter()

    private var cache: [Key: CandleSeries] = [:]
    private var sources: [Key: Source] = [:]
    private var inFlight: Set<Key> = []

    init() {}

    // MARK: - Public API

    /// Return the best available series for this symbol + interval.
    /// Synchronous: hits cache, or returns the synthetic `fallback` while
    /// triggering a background fetch.
    func series(for symbol: String,
                interval: BarInterval,
                fallback: CandleSeries) -> CandleSeries
    {
        let key = Key(symbol: symbol, interval: interval)
        if let cached = cache[key] { return cached }
        scheduleFetchIfNeeded(key, fallback: fallback)
        return fallback
    }

    /// Best label for the price-header badge.
    func source(for symbol: String, interval: BarInterval) -> Source {
        sources[Key(symbol: symbol, interval: interval)] ?? .demo
    }

    // MARK: - Fetching

    private func scheduleFetchIfNeeded(_ key: Key, fallback: CandleSeries) {
        guard !inFlight.contains(key) else { return }
        guard let yahooInterval = mapInterval(key.interval) else {
            // Interval not supported live (e.g. 4h). Mark demo so the UI
            // doesn't keep retrying.
            sources[key] = .demo
            return
        }
        inFlight.insert(key)
        let symbol = ySymbol(key.symbol)
        let range = mapRange(key.interval)
        _ = fallback   // already in the caller's hand; pulled in only to
                       // document intent + keep the call site symmetrical.
        Task { @MainActor in
            do {
                let series = try await adapter.fetch(symbol: symbol,
                                                     interval: yahooInterval,
                                                     range: range)
                self.handleFetchSuccess(key: key, series: series)
            } catch {
                self.handleFetchFailure(key: key, error: error)
            }
        }
    }

    private func handleFetchSuccess(key: Key, series: CandleSeries) {
        inFlight.remove(key)
        // Re-stamp the symbol so views that check it see the demo's
        // internal id, not Yahoo's quirks (e.g. BRK-B vs BRK.B).
        let stamped = CandleSeries(symbol: key.symbol,
                                   interval: key.interval,
                                   candles: Array(series.candles),
                                   tz: series.tz,
                                   session: series.session)
        cache[key] = stamped
        sources[key] = .live(fetchedAt: Date())
    }

    private func handleFetchFailure(key: Key, error: any Error) {
        inFlight.remove(key)
        // Keep returning the synthetic fallback. Stamp the source so the
        // badge can read "Demo · rate-limited" or similar.
        sources[key] = .error(String(describing: error))
    }

    // MARK: - Yahoo quirks

    /// Yahoo's two-faced symbol convention:
    /// • US class-share separator is `-`, not `.` — `BRK.B` ⇢ `BRK-B`.
    /// • Non-US listings carry an exchange suffix delimited by `.` that
    ///   must be preserved verbatim — `600519.SS` (Shanghai), `0700.HK`
    ///   (Hong Kong), `7203.T` (Tokyo), `RIO.L` (London), `BMW.DE`
    ///   (Frankfurt), and so on. Naively replacing every `.` with `-`
    ///   (the previous behaviour) silently broke every A-share, H-share,
    ///   and ADR-equivalent symbol — the request URL came back 404 and
    ///   the chart fell through to the synthetic GBM fallback forever.
    ///
    /// Resolution: only substitute the `.` when the trailing token is
    /// *not* one of Yahoo's documented exchange suffixes.
    private func ySymbol(_ id: String) -> String {
        if let dotIdx = id.lastIndex(of: ".") {
            let suffix = String(id[id.index(after: dotIdx)...]).uppercased()
            if Self.exchangeSuffixes.contains(suffix) { return id }
        }
        return id.replacingOccurrences(of: ".", with: "-")
    }

    /// Yahoo exchange suffixes seen in the wild (subset that matters
    /// most for retail tickers). Expand as needed.
    private static let exchangeSuffixes: Set<String> = [
        "SS", "SZ",        // Shanghai / Shenzhen (China A-shares)
        "HK",              // Hong Kong
        "T",               // Tokyo
        "L",               // London
        "TO", "V",         // Toronto, TSX-V
        "PA", "DE", "F",   // Paris, Xetra, Frankfurt
        "AS", "BR", "MI",  // Amsterdam, Brussels, Milan
        "MC", "LS",        // Madrid, Lisbon
        "ST", "HE", "OL",  // Stockholm, Helsinki, Oslo
        "CO",              // Copenhagen
        "VI", "WA", "PR",  // Vienna, Warsaw, Prague
        "BK", "JK",        // Bangkok, Jakarta
        "TW", "TWO",       // Taipei
        "SI",              // Singapore
        "KS", "KQ",        // KOSPI / KOSDAQ
        "AX",              // Sydney
        "NS", "BO",        // NSE / BSE India
        "SA", "MX",        // São Paulo, Mexico
        "JO",              // Johannesburg
    ]

    private func mapInterval(_ bi: BarInterval) -> Interval? {
        switch bi {
        case .m1:  return .m1
        case .m5:  return .m5
        case .m15: return .m15
        case .m30: return .m30
        case .h1:  return .h1
        case .h4:  return nil       // Yahoo has no 4h — would need resample
        case .d1:  return .d1
        case .w1:  return .w1
        case .mo1: return .mo1
        }
    }

    /// Pick a Yahoo range that returns *true* bars at the requested
    /// interval (not silently aggregated). `range=max` is a trap: for
    /// tickers older than ~3 years Yahoo squeezes the response into
    /// ~162 bars regardless of interval — so a "1d/max" pull for MSFT
    /// (40-year history) actually returns 92-day-spaced "quarterly"
    /// bars. Shorter ranges keep the resolution honest.
    private func mapRange(_ bi: BarInterval) -> Range {
        switch bi {
        case .m1:  return .d1     // 7-day cap
        case .m5:  return .m1     // ~60-day intraday cap
        case .m15: return .m1
        case .m30: return .m1     // 30-min data caps at ~60 days too —
                                  // `.m3` (90 days) used to silently
                                  // fail with "network unavailable" on
                                  // the Overview's 1W view.
        case .h1:  return .y1     // ~1600 hourly bars
        case .h4:  return .y1     // unused (h1 fallback)
        case .d1:  return .y5     // ~1260 real daily bars (not aggregated)
        case .w1:  return .y5     // ~260 real weekly bars
        case .mo1: return .y5     // ~60 real monthly bars
        }
    }
}
