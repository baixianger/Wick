import Foundation

/// A native capability the chat agent can call — the agent's "hands". Tools
/// do the things an LLM can't reason into existence: fetch prices, compute
/// indicators, pull news. PiSwift (or any agent runtime) registers these and
/// invokes `call` when the model emits a tool use.
///
/// The fixed-flow pipeline (`TradingFloor.analyze`) and the interactive chat
/// agent both ultimately reach data through these same tools — that's what
/// lets the two modes share one substrate.
public protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    /// `arguments` is the JSON object the model supplied; return plain text
    /// (or JSON) for the model to read back.
    func call(arguments: Data) async throws -> String
}

/// Token-/length-bounding for tool results handed back to the model. Tool
/// outputs (especially web reads — a page's text, a DOM outline, a JSON
/// response) can be arbitrarily large; feeding the whole thing back blows the
/// context window and drowns the signal. `ToolResultBounding.bound` clamps a
/// string to a character budget, cutting on a UTF-8-safe boundary and appending
/// a clear, machine-readable `…[truncated N chars]` marker so the model knows
/// the result was cut (and roughly by how much) rather than silently ending.
///
/// Lives here (Foundation-only package) rather than app-side so the bounding
/// logic is unit-testable without WebKit; the app-side `web.*` tools call it on
/// every result. The character budget is a coarse proxy for tokens (~4 chars/
/// token for English; CJK runs denser, so the budget is conservative).
public enum ToolResultBounding {
    /// Default per-result character budget. ~8k chars ≈ 2k tokens — generous
    /// enough for a page outline or a trimmed JSON body, small enough that a
    /// handful of tool calls in one turn don't exhaust the window.
    public static let defaultLimit = 8_000

    /// Clamp `text` to `limit` characters. Returns `text` unchanged when it
    /// already fits; otherwise the first `limit` characters plus a
    /// `…[truncated N chars]` suffix noting how many were dropped. Never splits
    /// a Swift `Character` (grapheme) — `String.prefix(_:)` is grapheme-safe —
    /// so the result is always valid text.
    public static func bound(_ text: String, limit: Int = defaultLimit) -> String {
        guard limit > 0 else { return "" }
        if text.count <= limit { return text }
        let kept = String(text.prefix(limit))
        let dropped = text.count - kept.count
        return kept + "\n…[truncated \(dropped) chars]"
    }
}

/// Describes a tool to the model: name, what it does, and a JSON Schema for
/// its parameters. Kept as a raw schema string so it maps onto any runtime's
/// function-calling format without a dependency.
public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    public let parametersJSONSchema: String

    public init(name: String, description: String, parametersJSONSchema: String) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
    }
}

/// Exposes the host's market data to the agent. Backed by the same
/// `MarketDataProvider` the fixed flow uses, so both modes see identical data.
public struct MarketDataTool: AgentTool {
    public let data: any MarketDataProvider

    public init(data: any MarketDataProvider) { self.data = data }

    public var spec: ToolSpec {
        ToolSpec(
            name: "get_market_data",
            description: "Fetch a point-in-time snapshot for a ticker: last price, "
                + "price-action summary, technical indicators, key fundamentals, and recent news.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "symbol": { "type": "string", "description": "Ticker symbol, e.g. NVDA" },
                "asOf":   { "type": "string", "description": "ISO-8601 date; defaults to today" }
              },
              "required": ["symbol"]
            }
            """
        )
    }

    private struct Args: Decodable { let symbol: String; let asOf: String? }

    public func call(arguments: Data) async throws -> String {
        let args = try JSONDecoder().decode(Args.self, from: arguments)
        let date = args.asOf.flatMap { ISO8601DateFormatter().date(from: $0) } ?? .now
        let snap = try await data.snapshot(symbol: args.symbol, asOf: date)
        // Hand the model a compact, readable block (not raw JSON it must parse).
        let funds = snap.fundamentals.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        return """
        \(snap.symbol) as of \(snap.asOf.formatted(date: .abbreviated, time: .omitted))
        Last price: \(snap.lastPrice.map { String(format: "%.2f", $0) } ?? "n/a")
        Price action: \(snap.priceSummary)
        Technicals: \(snap.technicals)
        Fundamentals: \(funds.isEmpty ? "n/a" : funds)
        News:
        \(snap.news.map { "- \($0)" }.joined(separator: "\n"))
        """
    }
}
