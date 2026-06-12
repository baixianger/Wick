import Foundation
import Observation
import CoreCharts
import DataAdapters
import TradingFloor

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
        case error(String)               // permanent failure (won't retry)
        /// A transient fetch fault (throttle / network blip) is being retried
        /// with backoff. `attempt` is the 1-based retry number in flight — the
        /// badge shows "重试中 (n)" while the synthetic fallback renders.
        case retrying(attempt: Int)
        /// Backoff retries were exhausted. The source is treated as
        /// temporarily down; the fallback keeps rendering. EastMoney's
        /// push2his throttle is transient and self-heals, so a later user
        /// action (symbol/interval revisit) re-arms a fresh fetch.
        case unavailable
    }

    private struct Key: Hashable {
        let symbol: String
        let interval: BarInterval
    }

    @ObservationIgnored
    private let adapter = YahooFinanceAdapter()

    /// Chinese A-share / HK source (EastMoney). One instance per store so its
    /// internal rate limiter is shared across this store's fetches.
    @ObservationIgnored
    private let eastMoney = EastMoneyChartAdapter()

    private var cache: [Key: CandleSeries] = [:]
    private var sources: [Key: Source] = [:]
    private var inFlight: Set<Key> = []

    /// Backoff bookkeeping for transient fetch faults. `retryAttempts` counts
    /// failures so far for a key; `retryTasks` holds the pending
    /// sleep-then-refetch Task so a fresh `scheduleFetchIfNeeded` doesn't stack
    /// duplicates and a success can cancel an in-flight backoff.
    @ObservationIgnored private var retryAttempts: [Key: Int] = [:]
    @ObservationIgnored private var retryTasks: [Key: Task<Void, Never>] = [:]

    /// Cap on transient-fault retries before a key settles into `.unavailable`.
    /// Five attempts at 2/4/8/16/30 s ≈ 1 min of self-heal headroom — enough to
    /// ride out an EastMoney push2his throttle without hammering it.
    private static let maxRetries = 5

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
        // A backoff retry is already armed for this key — let it run rather
        // than firing a competing immediate fetch. (The retry Task clears this
        // slot just before it re-enters here, so the next attempt isn't blocked.)
        guard retryTasks[key] == nil else { return }

        // Fold broker `SYMBOL:MIC` forms (e.g. `00100:XHKG`) to canonical first,
        // so an imported HK / A-share holding routes to EastMoney instead of
        // failing `CNSymbol.parse` and falling through to a flat Yahoo miss.
        let resolved = BrokerSymbol.canonical(key.symbol)

        // Chinese A-share / HK tickers (`.SS` / `.SZ` / `.HK`, or any form
        // `CNSymbol.parse` recognizes) go to EastMoney — the same source the
        // analysts use — so the chart and the agent never disagree on price.
        // Everything else stays on Yahoo via CandleKit below.
        if let canonical = CNSymbol.parse(resolved) {
            guard EastMoneyChartAdapter.supports(key.interval) else {
                // e.g. 4h — no EastMoney equivalent. Mark demo so the UI
                // stops retrying, matching the Yahoo unsupported-interval path.
                sources[key] = .demo
                return
            }
            inFlight.insert(key)
            Task { @MainActor in
                do {
                    let series = try await eastMoney.fetch(symbol: canonical,
                                                           interval: key.interval)
                    self.handleFetchSuccess(key: key, series: series)
                } catch {
                    self.handleFetchFailure(key: key, error: error, fallback: fallback)
                }
            }
            return
        }

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
                self.handleFetchFailure(key: key, error: error, fallback: fallback)
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
        // Recovered — tear down any backoff bookkeeping for this key.
        retryTasks[key]?.cancel()
        retryTasks[key] = nil
        retryAttempts[key] = nil
    }

    /// A fetch failed. Permanent faults settle immediately; transient ones
    /// (throttle / network blip — the common EastMoney push2his case) get a
    /// bounded exponential backoff retry, surfacing `.retrying` while waiting
    /// and `.unavailable` once attempts are spent. The synthetic fallback keeps
    /// rendering throughout.
    private func handleFetchFailure(key: Key, error: any Error, fallback: CandleSeries) {
        inFlight.remove(key)

        if Self.isPermanent(error) {
            retryTasks[key]?.cancel()
            retryTasks[key] = nil
            retryAttempts[key] = nil
            sources[key] = .error(String(describing: error))
            return
        }

        let attempt = (retryAttempts[key] ?? 0) + 1
        retryAttempts[key] = attempt
        guard attempt <= Self.maxRetries else {
            // Spent the budget — settle into "temporarily unavailable". The
            // throttle self-heals, so a later revisit (which clears state via a
            // fresh fetch) re-arms. Drop the attempt counter so that revisit
            // starts clean.
            retryTasks[key] = nil
            retryAttempts[key] = nil
            sources[key] = .unavailable
            return
        }

        sources[key] = .retrying(attempt: attempt)
        let delay = Self.backoffDelay(attempt: attempt)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            // Clear our own slot BEFORE re-entering so the pending-retry guard
            // in `scheduleFetchIfNeeded` doesn't reject the next attempt.
            self.retryTasks[key] = nil
            self.scheduleFetchIfNeeded(key, fallback: fallback)
        }
        retryTasks[key] = task
    }

    /// Classify a fetch error. Only structurally-permanent faults (an interval
    /// with no source mapping) are non-retryable; throttle / empty / network
    /// faults are transient and worth a backoff.
    private static func isPermanent(_ error: any Error) -> Bool {
        if case EastMoneyChartError.unsupportedInterval = error { return true }
        return false
    }

    /// Exponential backoff in seconds, capped: 2, 4, 8, 16, 30, … — about a
    /// minute of total headroom across `maxRetries` attempts.
    private static func backoffDelay(attempt: Int) -> Double {
        min(pow(2.0, Double(attempt)), 30)
    }

    // MARK: - Yahoo quirks

    /// Map symbol via the shared `YahooSymbol` helper (used by both
    /// this store and `WickMarketDataProvider` so chart streaming and
    /// agent snapshots agree on the URL they send Yahoo).
    private func ySymbol(_ id: String) -> String { YahooSymbol.map(id) }

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
