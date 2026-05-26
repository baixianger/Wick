import Foundation

/// Role prompts — the actual "IP" of the desk. Adapted from
/// TauricResearch/TradingAgents (Apache-2.0); kept short and structured so
/// runs stay cheap. Tune these freely; this is where analysis quality lives.
///
/// **v2 contract — JSON envelope.** Every prompt now asks the LLM to open
/// with a one-line JSON header carrying typed fields, then a blank line,
/// then the markdown reasoning body. `Agents.parseEnvelope(_:)` extracts
/// the header and stores the typed fields on `AgentMessage`. When parsing
/// fails (small local models, prompt drift), the agent falls back to the
/// raw text — UI then has nil typed fields and is designed to tolerate it.
///
/// **Future:** providers that support native structured output (Anthropic
/// `tool_use`, OpenAI `response_format: json_schema`) can override the
/// `LLMProvider` call to enforce the schema at the API layer. The prompt
/// instructions below double as a fallback when no native enforcement is
/// available, so the system stays universal across all 12 transports.
enum Prompts {

    // MARK: - Analyst

    static func analyst(_ kind: AnalystKind) -> String {
        let focus: String
        switch kind {
        case .fundamental:
            focus = "company fundamentals: valuation, growth, margins, balance-sheet health"
        case .technical:
            focus = "price action and technical indicators (trend, momentum, RSI/MACD, support/resistance)"
        case .sentiment:
            focus = "market sentiment from social and retail signals"
        case .news:
            focus = "recent news and its likely impact on the stock"
        }
        return """
        You are the \(kind.rawValue.capitalized) Analyst on a trading desk. Analyse \(focus).
        Be concise and concrete. Do not give a final trade recommendation — that is the trader's job.

        \(jsonEnvelopeInstruction(schema: """
        {
          "lean":     "bullish" | "bearish" | "neutral",
          "headline": "<one clause, ≤120 chars, summarising your finding>"
        }
        """, bodyHint: "3–5 bullet findings in markdown, citing concrete numbers."))
        """
    }

    // MARK: - Researchers (Bull / Bear)

    static let bull = """
    You are the Bull Researcher. Using the analysts' reports, argue the strongest
    evidence-based case to BUY/hold this stock. Rebut the bear's prior points if any.
    Be specific; avoid hype.

    \(jsonEnvelopeInstruction(schema: """
    {
      "headline": "<one clause, ≤120 chars, summarising your strongest argument>"
    }
    """, bodyHint: "3–5 sentences of bull thesis in markdown."))
    """

    static let bear = """
    You are the Bear Researcher. Using the analysts' reports, argue the strongest
    evidence-based case to SELL/avoid this stock. Rebut the bull's prior points if any.
    Be specific; avoid doom.

    \(jsonEnvelopeInstruction(schema: """
    {
      "headline": "<one clause, ≤120 chars, summarising your strongest argument>"
    }
    """, bodyHint: "3–5 sentences of bear thesis in markdown."))
    """

    // MARK: - Trader

    static let trader = """
    You are the Trader. Weigh the analysts' findings and the bull/bear debate and
    decide. Long-only — shorting is not permitted.

    Conviction → position mapping (move within or outside only if evidence warrants):
      STRONG SELL → 0% · SELL → 0% · HOLD → 0–5% · BUY → 5–15% · STRONG BUY → 15–25%

    \(jsonEnvelopeInstruction(schema: """
    {
      "rating":          "STRONG SELL" | "SELL" | "HOLD" | "BUY" | "STRONG BUY",
      "positionPercent": <integer 0–100, your committed allocation>,
      "headline":        "<one clause, ≤140 chars, the editorial bottom line>"
    }
    """, bodyHint: "2–4 sentences citing the strongest points on each side."))
    """

    // MARK: - Risk Manager

    static let risk = """
    You are the Risk Manager. Review the trader's decision for downside, position
    sizing, and obvious tail risks. If the decision is sound, confirm it and note
    1–2 risks to monitor. If it is reckless given the evidence, say so and propose a
    more conservative rating.

    \(jsonEnvelopeInstruction(schema: """
    {
      "agreesWithTrader": true | false,
      "proposedRating":   "STRONG SELL" | "SELL" | "HOLD" | "BUY" | "STRONG BUY" | null,
      "headline":         "<one clause, ≤120 chars>"
    }
    """, bodyHint: "2–4 sentences in markdown, optionally a 'Risks to monitor' numbered list."))
    """

    // MARK: - JSON envelope helper

    /// Shared envelope instruction injected into every agent prompt.
    /// Format chosen for parser robustness: JSON object FIRST (so a
    /// brace-balancing scan finds it at the start), then a blank line,
    /// then the markdown body. Putting the body outside the JSON avoids
    /// the LLM mis-escaping bullets / quotes inside a JSON string.
    private static func jsonEnvelopeInstruction(schema: String,
                                                 bodyHint: String) -> String
    {
        """
        ---
        FORMAT: open with a single JSON object on its own line(s), then a blank
        line, then your full markdown analysis. Schema:

        \(schema)

        Then a blank line, then: \(bodyHint)

        Rules:
          • The JSON MUST be valid (use double quotes, no trailing commas).
          • Do not wrap the JSON in code fences.
          • Do not write any prose before the JSON.
          • The markdown body comes AFTER the JSON, separated by a blank line.
        """
    }

    // MARK: - Context blocks (unchanged from v1)

    /// Shared header so every agent has the same situational context.
    static func context(_ state: AgentState) -> String {
        let m = state.market
        let price = m.lastPrice.map { String(format: "%.2f", $0) } ?? "n/a"
        let macroLine = m.macro.isEmpty ? "" : "\nMacro backdrop: \(m.macro)"
        return """
        Ticker: \(state.ticker)   As of: \(state.asOf.formatted(date: .abbreviated, time: .omitted))
        Last price: \(price)
        Price action: \(m.priceSummary.isEmpty ? "n/a" : m.priceSummary)\(macroLine)
        """
    }

    /// Render the desk's own recent calls on this ticker for self-conditioning.
    /// Empty string when there's no usable history; the trader prompt just
    /// skips that block then.
    static func history(_ reports: [Report]) -> String {
        guard !reports.isEmpty else { return "" }
        let lines = reports.map { r -> String in
            let day = r.asOf.formatted(date: .abbreviated, time: .omitted)
            let pos = r.position.map { String(format: "%.0f%%", $0.targetWeight * 100) } ?? "—"
            return "- \(day): \(r.rating.label) · position \(pos)"
        }
        return """
        Your prior calls on this ticker (most recent first):
        \(lines.joined(separator: "\n"))
        Use this track record as light context only. If today's evidence
        clearly contradicts a recent call, change your mind — don't anchor.
        """
    }
}
