import Foundation
import CoreCharts
import DataAdapters
import TradingFloor

/// Wick's concrete `MarketDataProvider` for the TradingFloor desk. Backed by
/// CandleKit's Yahoo adapter (no API key needed → works on first launch), it
/// computes a readable technical/price summary from the daily candles.
///
/// Wrap it in `CachingMarketDataProvider` to conserve quota:
/// ```swift
/// let data = CachingMarketDataProvider(wrapping: WickMarketDataProvider())
/// ```
///
/// Fundamentals and news are intentionally empty here — Yahoo's chart endpoint
/// doesn't carry them. A future Finnhub-backed provider fills those fields
/// (BYO key); the analysts already degrade gracefully when a section is empty.
struct WickMarketDataProvider: MarketDataProvider {
    let adapter = YahooFinanceAdapter()

    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        // ~1y of daily bars: enough for SMA200, RSI, MACD, and 52w range.
        let series = try await adapter.fetch(symbol: YahooSymbol.map(symbol),
                                              interval: .d1, range: .y1)
        let closes = series.candles.map(\.close)
        guard let last = closes.last else {
            return MarketSnapshot(symbol: symbol, asOf: asOf)
        }

        // Indicator math is shared with the server via TradingFloor.Technicals.
        return MarketSnapshot(
            symbol: symbol,
            asOf: asOf,
            lastPrice: last,
            priceSummary: Technicals.priceSummary(closes: closes,
                                                  highs: series.candles.map(\.high),
                                                  lows: series.candles.map(\.low),
                                                  last: last),
            technicals: Technicals.technicalsSummary(closes: closes, last: last)
        )
    }
}
