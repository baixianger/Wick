import Foundation
import CoreCharts

/// Apple Stocks-style time-range picker for the Overview tab. Each case
/// maps to a *bar interval* + *trailing window count* — 1D pulls 5-min
/// bars, 5Y pulls weekly bars, ALL pulls monthly. Matches the live Apple
/// Stocks app exactly.
enum OverviewRange: String, CaseIterable, Identifiable, Hashable {
    case d1  = "1D"
    case w1  = "1W"
    case m1  = "1M"
    case m3  = "3M"
    case m6  = "6M"
    case ytd = "YTD"
    case y1  = "1Y"
    case y2  = "2Y"
    case y5  = "5Y"
    case y10 = "10Y"
    case all = "ALL"

    var id: String { rawValue }

    /// Resolution this range is rendered at. Calibrated against the
    /// 1D + 5-min reference (~78 bars over a typical Overview chart
    /// width = ~9 pt / bar) so the wave reads with the same density
    /// across every range — neither crowded nor sparse. Picks the
    /// closest available `BarInterval` to that target since the
    /// supported set (5m / 15m / 30m / 1h / 1d / 1w / 1mo) has no
    /// "2 h" option, which is why 1M sits at 1 h (~2× the reference)
    /// rather than the nearest sparser daily.
    var underlyingInterval: BarInterval {
        switch self {
        case .d1:  return .m5
        case .w1:  return .m30
        case .m1:  return .h1
        case .m3, .m6, .ytd, .y1, .y2: return .d1
        case .y5, .y10: return .w1
        case .all: return .mo1
        }
    }

    /// Trailing bar count at `underlyingInterval`. Numbers approximate
    /// the wall-clock window each label promises.
    func bars(intervalSeriesCount n: Int) -> Int {
        switch self {
        case .d1:  return min(n, 78)          // 6.5 h × 12 (5-min)
        case .w1:  return min(n, 65)          // 5 d × 13 (30-min)
        case .m1:  return min(n, 22 * 7)      // 22 d × ~7 (hourly)
        case .m3:  return min(n, 66)
        case .m6:  return min(n, 132)
        case .ytd: return min(n, ytdTradingDays)
        case .y1:  return min(n, 252)
        case .y2:  return min(n, 504)
        case .y5:  return min(n, 260)
        case .y10: return min(n, 520)
        case .all: return n
        }
    }

    var subtitle: String {
        switch self {
        case .d1:  return "Past Day"
        case .w1:  return "Past Week"
        case .m1:  return "Past Month"
        case .m3:  return "Past 3 Months"
        case .m6:  return "Past 6 Months"
        case .ytd: return "Year to Date"
        case .y1:  return "Past Year"
        case .y2:  return "Past 2 Years"
        case .y5:  return "Past 5 Years"
        case .y10: return "Past 10 Years"
        case .all: return "All Time"
        }
    }

    private var ytdTradingDays: Int {
        let cal = Calendar(identifier: .gregorian)
        let day = cal.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return Int(Double(day) * 0.7)
    }
}

// MARK: - Chart scale (5 coarse options for the technical Chart tab)

/// Time-resolution picker for the Chart tab — coarser than Overview
/// because the technical view (K-line + indicators + sub-panes) is most
/// useful at hour / day / week / month granularity, not Apple's
/// consumer-facing "past 3 months" buckets.
enum ChartScale: String, CaseIterable, Identifiable, Hashable {
    case h1  = "1H"
    case d1  = "1D"
    case w1  = "1W"
    case mo1 = "1M"
    case all = "All"

    var id: String { rawValue }

    var underlyingInterval: BarInterval {
        switch self {
        case .h1:  return .h1
        case .d1:  return .d1
        case .w1:  return .w1
        case .mo1: return .mo1
        case .all: return .mo1
        }
    }

    func bars(intervalSeriesCount n: Int) -> Int {
        switch self {
        case .h1:  return min(n, 168)
        case .d1:  return min(n, 90)
        case .w1:  return min(n, 52)
        case .mo1: return min(n, 60)
        case .all: return n
        }
    }
}
