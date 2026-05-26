import Foundation

/// A point-in-time view of everything the agents reason about. Kept as plain
/// `String`/number fields the LLM can read directly — the agents don't call
/// tools mid-run; the host gathers the data once and the engine reasons over
/// this snapshot. (This is the simplification vs TradingAgents' live tool
/// calls; it removes the ReAct tool-loop and makes runs cheaper/predictable.)
public struct MarketSnapshot: Sendable, Codable {
    public var symbol: String
    public var asOf: Date
    public var lastPrice: Double?
    /// Human-readable price-action summary, e.g. "+4.2% over 30d, near 52w high".
    public var priceSummary: String
    /// Indicator readings already computed by the host (IndicatorKit), e.g.
    /// "RSI(14) 68 (overbought); MACD bullish crossover 3d ago".
    public var technicals: String
    /// Key fundamentals as label→value, e.g. ["P/E": "31.4", "Rev YoY": "+12%"].
    public var fundamentals: [String: String]
    /// Recent headlines / social sentiment lines.
    public var news: [String]
    /// Macro backdrop (rates, inflation, yield curve, jobs) — same for every
    /// ticker on a given day. Filled by a macro source like FRED.
    public var macro: String

    public init(symbol: String, asOf: Date, lastPrice: Double? = nil,
                priceSummary: String = "", technicals: String = "",
                fundamentals: [String: String] = [:], news: [String] = [],
                macro: String = "") {
        self.symbol = symbol
        self.asOf = asOf
        self.lastPrice = lastPrice
        self.priceSummary = priceSummary
        self.technicals = technicals
        self.fundamentals = fundamentals
        self.news = news
        self.macro = macro
    }

    /// Render the slice an analyst of a given kind cares about, for prompting.
    public func brief(for kind: AnalystKind) -> String {
        switch kind {
        case .fundamental:
            let lines = fundamentals.map { "- \($0.key): \($0.value)" }.sorted()
            return lines.isEmpty ? "No fundamentals available." : lines.joined(separator: "\n")
        case .technical:
            return technicals.isEmpty ? "No indicator data available." : technicals
        case .sentiment, .news:
            return news.isEmpty ? "No recent news available." : news.map { "- \($0)" }.joined(separator: "\n")
        }
    }
}

/// The host (Wick) implements this against CandleKit / Yahoo / IndicatorKit.
public protocol MarketDataProvider: Sendable {
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot
}

/// Deterministic stand-in for tests and SwiftUI previews — no network.
public struct StubMarketDataProvider: MarketDataProvider {
    public init() {}
    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        MarketSnapshot(
            symbol: symbol, asOf: asOf, lastPrice: 123.45,
            priceSummary: "+4.2% over 30d, ~2% below 52-week high.",
            technicals: "RSI(14) 64; MACD bullish, signal crossed 3 sessions ago; price above 50/200 SMA.",
            fundamentals: ["P/E": "28.1", "Rev YoY": "+11%", "Gross margin": "54%"],
            news: ["Q earnings beat on revenue, light guidance.",
                   "Analyst upgrade to Overweight.",
                   "Social sentiment mildly positive after product launch."]
        )
    }
}
