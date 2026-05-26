import Foundation
import CoreCharts

/// Bar-interval picker shown above the chart. Each non-ALL case maps 1:1
/// onto `CoreCharts.BarInterval`; "ALL" means "stay on whatever interval
/// you're already viewing and zoom out to show every bar."
enum IntervalOption: String, CaseIterable, Identifiable, Hashable {
    case m5  = "5min"
    case m15 = "15min"
    case m30 = "30min"
    case h1  = "1h"
    case h4  = "4h"
    case d1  = "1d"
    case w1  = "1w"
    case mo1 = "1mo"
    case all = "ALL"

    var id: String { rawValue }

    /// Underlying CoreCharts BarInterval. `ALL` carries no interval of its
    /// own — the caller keeps the previously-selected interval and just
    /// calls `coord.fitContent()`.
    var barInterval: BarInterval? {
        switch self {
        case .m5:  return .m5
        case .m15: return .m15
        case .m30: return .m30
        case .h1:  return .h1
        case .h4:  return .h4
        case .d1:  return .d1
        case .w1:  return .w1
        case .mo1: return .mo1
        case .all: return nil
        }
    }

    /// "Natural" trailing window each interval ships with — chosen to land
    /// at a calendar unit the user immediately recognises (5m ≈ 1 day,
    /// 1h ≈ 1 month, 1d ≈ 3 months, 1w ≈ 1 year, 1mo ≈ 5 years). Avoids
    /// the trap where a fixed 200-bar window makes "1d" look like a year+
    /// of data because the labels cross a calendar boundary.
    var defaultVisibleBars: Int {
        switch self {
        case .m5:  return 78    // 1 trading day (~6.5h × 12 bars/h)
        case .m15: return 26    // 1 trading day
        case .m30: return 65    // 1 trading week
        case .h1:  return 168   // ≈ 1 month
        case .h4:  return 60    // ≈ 2 months
        case .d1:  return 66    // ≈ 3 months
        case .w1:  return 52    // ≈ 1 year
        case .mo1: return 60    // ≈ 5 years
        case .all: return 200   // unused — fitContent path
        }
    }
}

/// Synthetic ticker bundle. One series per BarInterval, each with its own
/// deterministic GBM walk so the panes show plausibly-different shapes
/// across timeframes.
struct Ticker: Identifiable, Hashable {
    let id: String           // symbol
    let symbol: String       // display ticker
    let name: String         // company / index name
    /// Series indexed by interval. Always populated for every non-ALL case
    /// of IntervalOption (8 entries). Generated upfront in `gen(...)`.
    let series: [BarInterval: CandleSeries]

    static let samples: [Ticker] = [
        gen(symbol: "AAPL",  name: "Apple Inc.",            seed: 11,  start: 180,  drift: 0.0003,  vol: 0.012),
        gen(symbol: "MSFT",  name: "Microsoft Corporation", seed: 22,  start: 340,  drift: 0.0004,  vol: 0.011),
        gen(symbol: "NVDA",  name: "NVIDIA Corporation",    seed: 33,  start: 420,  drift: 0.0006,  vol: 0.025),
        gen(symbol: "GOOGL", name: "Alphabet Inc.",         seed: 44,  start: 138,  drift: 0.0002,  vol: 0.013),
        gen(symbol: "AMZN",  name: "Amazon.com, Inc.",      seed: 55,  start: 175,  drift: 0.0003,  vol: 0.015),
        gen(symbol: "META",  name: "Meta Platforms",        seed: 66,  start: 510,  drift: 0.0001,  vol: 0.018),
        gen(symbol: "TSLA",  name: "Tesla, Inc.",           seed: 77,  start: 240,  drift: -0.0001, vol: 0.030),
        gen(symbol: "BRK.B", name: "Berkshire Hathaway",    seed: 88,  start: 410,  drift: 0.0002,  vol: 0.008),
    ]

    var dailySeries: CandleSeries {
        series[.d1] ?? CandleSeries(symbol: symbol, interval: .d1, candles: [])
    }

    func series(forInterval i: BarInterval) -> CandleSeries {
        series[i] ?? dailySeries
    }

    private static func gen(symbol: String,
                            name: String,
                            seed: UInt64,
                            start: Double,
                            drift: Double,
                            vol: Double) -> Ticker
    {
        var dict: [BarInterval: CandleSeries] = [:]
        // Bar counts chosen so each interval covers a "reasonable" span at
        // ~6pt-per-bar. Intraday rolls 500; daily/weekly/monthly extend.
        let plan: [(BarInterval, Int)] = [
            (.m5,  500),
            (.m15, 500),
            (.m30, 500),
            (.h1,  500),
            (.h4,  500),
            (.d1,  1500),
            (.w1,  600),
            (.mo1, 240),
        ]
        for (interval, n) in plan {
            // Salt the seed per-interval so each timeframe has its own walk —
            // otherwise the 5m chart looks like a stretched 1d.
            let saltedSeed = seed &+ UInt64(bitPattern: Int64(interval.approximateSeconds))
            // Volatility scales with √(barLength) — a 5-min bar should
            // wiggle less than a monthly bar at the same drift target.
            let scale = (interval.approximateSeconds / 86_400).squareRoot()
            dict[interval] = Fixtures.gbm(n: n,
                                          seed: saltedSeed,
                                          mu: drift * scale,
                                          sigma: vol * max(0.25, scale),
                                          startPrice: start,
                                          symbol: symbol,
                                          interval: interval)
        }
        return Ticker(id: symbol, symbol: symbol, name: name, series: dict)
    }
}

// MARK: - Header / sparkline conveniences

extension Ticker {

    /// Live-or-fallback series at the given interval. Reads through the
    /// shared `LiveDataStore`; while the Yahoo fetch is in flight (or if
    /// it ever fails) returns the deterministic synthetic series.
    @MainActor
    func liveSeries(_ interval: BarInterval, store: LiveDataStore) -> CandleSeries {
        store.series(for: symbol,
                     interval: interval,
                     fallback: series(forInterval: interval))
    }

    /// Series trimmed to the trailing window required by an Apple-Stocks
    /// `OverviewRange`. Picks the right bar interval (5min for 1D, daily
    /// for 1M, weekly for 5Y, monthly for ALL) so chart resolution
    /// matches what each label promises.
    @MainActor
    func overviewSeries(_ range: OverviewRange, store: LiveDataStore) -> CandleSeries {
        let bi = range.underlyingInterval
        let full = liveSeries(bi, store: store)
        let n = range.bars(intervalSeriesCount: full.candles.count)
        let slice = Array(full.candles.suffix(n))
        return CandleSeries(symbol: full.symbol,
                            interval: bi,
                            candles: slice,
                            tz: full.tz,
                            session: full.session)
    }

    /// Last close of the daily series — used by the watchlist row.
    var lastPrice: Double { dailySeries.candles.last?.close ?? 0 }

    /// Change between the last close and `barCount` bars ago at the given
    /// interval. `nil` barCount means "min(seriesCount, 60)" — a sensible
    /// default for header subtitle copy.
    func change(over interval: BarInterval, barCount: Int? = nil) -> Double {
        let candles = series(forInterval: interval).candles
        guard let last = candles.last else { return 0 }
        let span = barCount ?? min(candles.count, 60)
        let baseIdx = max(0, candles.count - span)
        return last.close - candles[baseIdx].close
    }

    func changePct(over interval: BarInterval, barCount: Int? = nil) -> Double {
        let candles = series(forInterval: interval).candles
        guard let last = candles.last else { return 0 }
        let span = barCount ?? min(candles.count, 60)
        let baseIdx = max(0, candles.count - span)
        let base = candles[baseIdx].close
        return base == 0 ? 0 : (last.close - base) / base * 100
    }
}
