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
        // When the data came from `StubMarketDataProvider`, prepend an
        // explicit "this is sample data" banner so the analyst LLM
        // doesn't produce an authoritative report from fabricated
        // numbers. Filter the marker keys (`_stub`, `Source`) out of
        // the fundamentals block so they don't leak into the prompt
        // as if they were real fields.
        let stubBanner = isStub
            ? "⚠️ Sample data — no live market provider configured. Refuse to give actionable analysis and ask the user to set up a real data source.\n\n"
            : ""
        switch kind {
        case .fundamental:
            let visible = fundamentals.filter {
                $0.key != StubMarketDataProvider.stubMarkerKey && $0.key != "Source"
            }
            let lines = visible.map { "- \($0.key): \($0.value)" }.sorted()
            let body = lines.isEmpty ? "No fundamentals available." : lines.joined(separator: "\n")
            return stubBanner + body
        case .technical:
            return stubBanner + (technicals.isEmpty ? "No indicator data available." : technicals)
        case .sentiment, .news:
            return stubBanner + (news.isEmpty ? "No recent news available." : news.map { "- \($0)" }.joined(separator: "\n"))
        }
    }
}

/// The host (Wick) implements this against CandleKit / Yahoo / IndicatorKit.
public protocol MarketDataProvider: Sendable {
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot
}

/// Deterministic stand-in for tests, SwiftUI previews, and the WickMCP
/// helper's "no FMP key configured" fallback. The marker `Source` /
/// `_stub` fundamentals key lets downstream surfaces (tool renderers,
/// LLM prompts) detect that the data is fake instead of pretending it's
/// real — feeding a stub snapshot into a Wicker desk run without flagging
/// it produced credible-looking but completely fabricated reports.
public struct StubMarketDataProvider: MarketDataProvider {
    /// `fundamentals` key set by this provider; consumers can check for
    /// it to decide whether to skip / warn / refuse the snapshot.
    public static let stubMarkerKey = "_stub"

    public init() {}
    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        MarketSnapshot(
            symbol: symbol, asOf: asOf, lastPrice: 123.45,
            priceSummary: "+4.2% over 30d, ~2% below 52-week high.",
            technicals: "RSI(14) 64; MACD bullish, signal crossed 3 sessions ago; price above 50/200 SMA.",
            fundamentals: [
                Self.stubMarkerKey: "true",
                "Source": "stub (no live provider configured)",
                "P/E": "28.1", "Rev YoY": "+11%", "Gross margin": "54%"
            ],
            news: ["[stub] Q earnings beat on revenue, light guidance.",
                   "[stub] Analyst upgrade to Overweight.",
                   "[stub] Social sentiment mildly positive after product launch."]
        )
    }
}

/// Convenience predicate. Marker stays on the snapshot through the
/// decorator chain (financial / news / macro decorators only ADD keys),
/// so a Markdown renderer downstream can show a "⚠️ sample data" banner.
public extension MarketSnapshot {
    var isStub: Bool {
        fundamentals[StubMarketDataProvider.stubMarkerKey] == "true"
    }
}
