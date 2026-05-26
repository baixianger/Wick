import Foundation

/// Pure indicator math + readable summaries, shared by every data provider
/// (the app's Yahoo bridge and the server's FMP provider) so there's one
/// source of truth. No dependencies — just arrays of prices in, strings out.
public enum Technicals {

    public static func sma(_ values: [Double], period: Int) -> Double? {
        guard values.count >= period else { return nil }
        return values.suffix(period).reduce(0, +) / Double(period)
    }

    public static func ema(_ values: [Double], period: Int) -> [Double] {
        guard values.count >= period else { return [] }
        let k = 2.0 / Double(period + 1)
        var prev = values.prefix(period).reduce(0, +) / Double(period)   // seed with SMA
        var result = [prev]
        for v in values.dropFirst(period) {
            prev = v * k + prev * (1 - k)
            result.append(prev)
        }
        return result
    }

    public static func rsi(_ closes: [Double], period: Int = 14) -> Double? {
        guard closes.count > period else { return nil }
        var gains = 0.0, losses = 0.0
        for i in closes.count - period ..< closes.count {
            let change = closes[i] - closes[i - 1]
            if change >= 0 { gains += change } else { losses -= change }
        }
        let avgLoss = losses / Double(period)
        guard avgLoss != 0 else { return 100 }
        let rs = (gains / Double(period)) / avgLoss
        return 100 - (100 / (1 + rs))
    }

    public static func macd(_ closes: [Double]) -> (macd: Double, signal: Double)? {
        let fast = ema(closes, period: 12)
        let slow = ema(closes, period: 26)
        guard !fast.isEmpty, !slow.isEmpty else { return nil }
        let n = min(fast.count, slow.count)
        let line = zip(fast.suffix(n), slow.suffix(n)).map { $0 - $1 }
        guard let now = line.last else { return nil }
        let signal = ema(line, period: 9)
        return (now, signal.last ?? now)
    }

    /// "RSI(14) 64; MACD bullish (…); price above 50-SMA; price above 200-SMA"
    public static func technicalsSummary(closes: [Double], last: Double) -> String {
        var parts: [String] = []
        if let r = rsi(closes) {
            let tag = r > 70 ? " (overbought)" : r < 30 ? " (oversold)" : ""
            parts.append(String(format: "RSI(14) %.0f%@", r, tag))
        }
        if let (m, s) = macd(closes) {
            parts.append("MACD \(m > s ? "bullish" : "bearish") (\(String(format: "%.2f", m)) vs \(String(format: "%.2f", s)))")
        }
        if let s = sma(closes, period: 50)  { parts.append("price \(last >= s ? "above" : "below") 50-SMA") }
        if let s = sma(closes, period: 200) { parts.append("price \(last >= s ? "above" : "below") 200-SMA") }
        return parts.joined(separator: "; ")
    }

    /// "+4.2% over ~30d, 2.1% from 52w high (lo–hi)"
    public static func priceSummary(closes: [Double], highs: [Double], lows: [Double], last: Double) -> String {
        var parts: [String] = []
        if closes.count > 30 {
            let prior = closes[closes.count - 31]
            if prior != 0 { parts.append(String(format: "%+.1f%% over ~30d", (last - prior) / prior * 100)) }
        }
        if let hi = highs.max(), let lo = lows.min(), hi > lo {
            parts.append(String(format: "%.1f%% from 52w high (%.2f–%.2f)", (last - hi) / hi * 100, lo, hi))
        }
        return parts.joined(separator: ", ")
    }
}
