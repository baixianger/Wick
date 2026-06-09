import Foundation
import CoreCharts
import TradingFloor

/// Bridges EastMoney's K-line endpoint (via TradingFloor's
/// `EastMoneyMarketDataProvider`) into CoreCharts' `CandleSeries`, so the
/// chart UI renders Chinese A-share / HK tickers from the *same* source the
/// analysts use — instead of Yahoo, which serves delayed, frequently
/// incomplete data for `.SS` / `.SZ` / `.HK` symbols (and is the least
/// defensible source for a sold app — see the data-source notes).
///
/// Date parsing + market timezone live here (app side) on purpose:
/// `EastMoneyMarketDataProvider` stays CoreCharts-free and Foundation-only
/// so it keeps building on Linux for WickServer. The conversion is the one
/// place both `CandleSeries` and the EastMoney provider are visible.
struct EastMoneyChartAdapter {
    let provider: EastMoneyMarketDataProvider

    init(provider: EastMoneyMarketDataProvider = EastMoneyMarketDataProvider()) {
        self.provider = provider
    }

    /// `true` iff this interval has an EastMoney K-line equivalent. `.h4` is
    /// the only chart interval without one (EastMoney, like Yahoo, has no
    /// 4-hour bar) — callers should mark such keys as demo, not retry.
    static func supports(_ interval: BarInterval) -> Bool {
        period(for: interval) != nil
    }

    /// Fetch `canonical` (already in `.SS` / `.SZ` / `.HK` form) at `interval`
    /// and build a `CandleSeries`. Throws `unsupportedInterval` for `.h4` and
    /// `emptySeries` when the endpoint returns nothing usable.
    func fetch(symbol canonical: String, interval: BarInterval) async throws -> CandleSeries {
        guard let period = Self.period(for: interval) else {
            throw EastMoneyChartError.unsupportedInterval(interval)
        }
        let tz = Self.timeZone(for: CNSymbol.market(canonical))
        let bars = try await provider.bars(symbol: canonical,
                                           period: period,
                                           limit: Self.limit(for: interval))

        let formatter = Self.formatter(intraday: period.isIntraday, tz: tz)
        let candles: [Candle] = bars.compactMap { bar in
            guard let time = formatter.date(from: bar.date) else { return nil }
            return Candle(time: time,
                          open: bar.open, high: bar.high,
                          low: bar.low, close: bar.close,
                          volume: bar.volume)
        }
        guard !candles.isEmpty else { throw EastMoneyChartError.emptySeries }

        return CandleSeries(symbol: canonical,
                            interval: interval,
                            candles: candles,
                            tz: tz,
                            session: Self.session(for: CNSymbol.market(canonical), tz: tz))
    }

    // MARK: - Mapping

    static func period(for interval: BarInterval) -> EastMoneyMarketDataProvider.KLinePeriod? {
        switch interval {
        case .m1:  return .m1
        case .m5:  return .m5
        case .m15: return .m15
        case .m30: return .m30
        case .h1:  return .h1
        case .h4:  return nil       // no EastMoney 4h bar — caller marks demo
        case .d1:  return .d1
        case .w1:  return .w1
        case .mo1: return .mo1
        }
    }

    /// Bar counts chosen so each interval covers a useful span without
    /// over-fetching: ~1 trading day of intraday detail, ~5 years of
    /// daily/weekly, ~10 years of monthly. EastMoney honours `lmt` directly,
    /// so unlike Yahoo's `range` there's no silent down-sampling to guard.
    private static func limit(for interval: BarInterval) -> Int {
        switch interval {
        case .m1:  return 240       // one A-share session = 240 minutes
        case .m5:  return 240       // ~5 sessions
        case .m15: return 240       // ~15 sessions
        case .m30: return 240       // ~30 sessions
        case .h1:  return 250       // ~60 sessions (4 hourly bars/day)
        case .h4:  return 250       // unused (no period mapping)
        case .d1:  return 1300      // ~5 years of daily bars
        case .w1:  return 300       // ~5.5 years of weekly bars
        case .mo1: return 120       // ~10 years of monthly bars
        }
    }

    private static func formatter(intraday: Bool, tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = intraday ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return f
    }

    private static func timeZone(for market: CNSymbol.Market?) -> TimeZone {
        switch market {
        case .hongKong: return TimeZone(identifier: "Asia/Hong_Kong") ?? .gmt
        default:        return TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        }
    }

    /// Trading session for x-axis non-trading-time compression. A-shares run
    /// 09:30–15:00 (with a lunch break the session enum can't model), HK
    /// 09:30–16:00.
    private static func session(for market: CNSymbol.Market?, tz: TimeZone) -> TradingSession {
        switch market {
        case .hongKong: return .equityCustom(open: "09:30", close: "16:00", tz: tz)
        default:        return .equityCustom(open: "09:30", close: "15:00", tz: tz)
        }
    }
}

enum EastMoneyChartError: Error, CustomStringConvertible {
    case unsupportedInterval(BarInterval)
    case emptySeries

    var description: String {
        switch self {
        case .unsupportedInterval(let i):
            return "EastMoney has no K-line period for interval \(i.rawValue)."
        case .emptySeries:
            return "EastMoney returned no bars."
        }
    }
}
