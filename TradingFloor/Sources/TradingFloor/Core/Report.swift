import Foundation

/// The five-tier verdict the desk converges on, mirroring the rating scale
/// used by TradingAgents. Ordered so `.rawValue` can drive a gauge / colour.
public enum Rating: Int, Sendable, CaseIterable, Codable {
    case strongSell = 0
    case sell
    case hold
    case buy
    case strongBuy

    public var label: String {
        switch self {
        case .strongSell: "Strong Sell"
        case .sell:       "Sell"
        case .hold:       "Hold"
        case .buy:        "Buy"
        case .strongBuy:  "Strong Buy"
        }
    }

    /// Map a typed label (as emitted in the trader's JSON envelope) to a
    /// `Rating`. Accepts the canonical labels and a few common variants.
    /// Returns nil on anything unrecognised — callers should fall back to
    /// the text-based `Rating.parse(_:)` then.
    public static func fromLabel(_ label: String) -> Rating? {
        switch label.uppercased().replacingOccurrences(of: "-", with: " ") {
        case "STRONG SELL":       return .strongSell
        case "SELL":              return .sell
        case "HOLD":              return .hold
        case "BUY":               return .buy
        case "STRONG BUY":        return .strongBuy
        default:                  return nil
        }
    }

    /// Parse the trader's decision. The trader is instructed to open with the
    /// verdict, so we read the first line first; we match whole WORDS, not
    /// substrings, so "buyback" / "oversell" don't trigger a false rating.
    static func parse(_ text: String) -> Rating {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        if let r = rating(in: firstLine) { return r }
        return rating(in: text) ?? .hold
    }

    private static func rating(in text: String) -> Rating? {
        let upper = text.uppercased()
        if upper.contains("STRONG SELL") || upper.contains("STRONG-SELL") { return .strongSell }
        if upper.contains("STRONG BUY")  || upper.contains("STRONG-BUY")  { return .strongBuy }
        let words = Set(upper.split { !$0.isLetter }.map(String.init))
        if words.contains("SELL") { return .sell }
        if words.contains("BUY")  { return .buy }
        if words.contains("HOLD") { return .hold }
        return nil
    }
}

/// Suggested portfolio allocation for the analysed ticker, as a fraction of
/// bankroll in `[0, 1]` (long-only). Ported from live-trade-bench's
/// portfolio-weight-as-action primitive: the trader is asked to commit to a
/// position size, not just a verbal lean. `cashWeight` is the implicit
/// complement so a `PositionSize` reads as "x% in this name, the rest in cash".
public struct PositionSize: Sendable, Codable, Equatable {
    public let targetWeight: Double
    public var cashWeight: Double { max(0, 1 - targetWeight) }

    public init(targetWeight: Double) {
        // Clamp to long-only [0, 1]; trader prompt forbids shorting in v1.
        self.targetWeight = min(max(0, targetWeight), 1)
    }

    /// Extract the trader's "Position: NN%" line, if present. Tolerates a few
    /// shapes: "Position: 15%", "ALLOC: 0.15", "Target weight: 0.2".
    static func parse(_ text: String) -> PositionSize? {
        // Try a percent first, then a 0..1 decimal. Match the LAST occurrence
        // so a value mentioned in passing earlier in the reasoning doesn't win.
        let lower = text.lowercased()
        let keyed = ["position", "alloc", "allocation", "target weight", "weight"]
        for line in text.split(separator: "\n").reversed() {
            let l = line.lowercased()
            guard keyed.contains(where: { l.contains($0 + ":") || l.hasPrefix($0) }) else { continue }
            if let pct = firstPercent(in: String(line)) { return PositionSize(targetWeight: pct / 100) }
            if let frac = firstFraction(in: String(line)) { return PositionSize(targetWeight: frac) }
        }
        // Fallback: scan the whole text for the first percent-with-keyword nearby.
        if let pct = firstPercent(in: lower), pct >= 0, pct <= 100 {
            return PositionSize(targetWeight: pct / 100)
        }
        return nil
    }

    private static func firstPercent(in s: String) -> Double? {
        // Match e.g. "15%", "7.5%", " 0%" — number immediately followed by %.
        var i = s.startIndex
        while i < s.endIndex {
            if let (n, end) = readNumber(s, from: i), end < s.endIndex, s[end] == "%" {
                return n
            }
            i = s.index(after: i)
        }
        return nil
    }
    private static func firstFraction(in s: String) -> Double? {
        var i = s.startIndex
        while i < s.endIndex {
            if let (n, _) = readNumber(s, from: i), n >= 0, n <= 1 { return n }
            i = s.index(after: i)
        }
        return nil
    }
    private static func readNumber(_ s: String, from start: String.Index) -> (Double, String.Index)? {
        var i = start
        var sawDigit = false
        var sawDot = false
        while i < s.endIndex {
            let c = s[i]
            if c.isNumber { sawDigit = true }
            else if c == "." && !sawDot { sawDot = true }
            else { break }
            i = s.index(after: i)
        }
        guard sawDigit, let d = Double(s[start..<i]) else { return nil }
        return (d, i)
    }
}

/// Three-way analyst stance. Emitted by Fundamental / Technical / Sentiment /
/// News analysts in their JSON envelope. Researchers don't carry a `lean` —
/// their stance is implicit in the role (Bull / Bear), so the UI reads role
/// instead. `nil` when the LLM didn't produce a parseable envelope.
public enum Lean: String, Sendable, Codable, CaseIterable {
    case bullish, bearish, neutral
}

/// One agent's contribution, kept verbatim so the UI can show the full,
/// interpretable transcript — the whole point of an agentic approach.
///
/// New in v2: agents are asked to emit a JSON header followed by the
/// markdown body. When parsing succeeds, the typed fields below are
/// populated; when it fails (older models, prompt drift, smaller local
/// LLMs), the raw text lands in `content` and typed fields stay nil.
/// **The UI must tolerate nil — never fall back to substring guessing
/// when the LLM was given the chance to emit typed output and didn't.**
public struct AgentMessage: Sendable, Identifiable, Codable {
    public let id: UUID
    public let role: String      // e.g. "Technical Analyst", "Bull Researcher"
    /// Raw LLM response (unparsed). Legacy callers like `Rating.parse(...)`
    /// keep operating on this; the typed fields are additive.
    public let content: String
    public let producedAt: Date

    // MARK: - Typed structured fields (v2 — optional, additive)

    /// Analyst's three-way stance. Trader / Risk / Researchers leave this nil.
    public let lean: Lean?
    /// ≤120-char one-clause takeaway. Used as card sub-header / verdict band.
    public let headline: String?
    /// Trader's verdict, parsed from the JSON envelope. Optional even when
    /// emitted — defends against the LLM dropping the field (TSLA sample
    /// dropped `Position:`).
    public let rating: Rating?
    /// Trader's committed allocation, 0…100 (long-only).
    public let positionPercent: Double?
    /// Risk Manager's verdict on the trader's call.
    public let agreesWithTrader: Bool?
    /// Risk's alternative rating when it overrides. Nil when agrees.
    public let proposedRating: Rating?
    /// Markdown body — everything after the JSON envelope, trimmed.
    /// Nil when no envelope parsed; UI then falls back to `content`.
    public let body: String?

    /// Legacy init — used by older code paths and by any agent whose JSON
    /// parse failed. Typed fields default to nil so cache stays decoded.
    public init(role: String, content: String, producedAt: Date = .now) {
        self.init(role: role, content: content, producedAt: producedAt,
                  lean: nil, headline: nil,
                  rating: nil, positionPercent: nil,
                  agreesWithTrader: nil, proposedRating: nil,
                  body: nil)
    }

    /// Full init — used by `Agents.swift` after a successful envelope parse.
    public init(role: String, content: String, producedAt: Date = .now,
                lean: Lean?,
                headline: String?,
                rating: Rating?,
                positionPercent: Double?,
                agreesWithTrader: Bool?,
                proposedRating: Rating?,
                body: String?)
    {
        self.id = UUID()
        self.role = role
        self.content = content
        self.producedAt = producedAt
        self.lean = lean
        self.headline = headline
        self.rating = rating
        self.positionPercent = positionPercent
        self.agreesWithTrader = agreesWithTrader
        self.proposedRating = proposedRating
        self.body = body
    }
}

/// The final, user-facing result of a desk run.
public struct Report: Sendable, Codable {
    public let ticker: String
    public let asOf: Date
    public let rating: Rating
    /// Trader-suggested position size for this ticker. Optional because the
    /// LLM may decline to commit a number; UI should fall back to the rating
    /// alone in that case. Codable-optional → older on-disk reports decode fine.
    public let position: PositionSize?
    public let summary: String              // the trader's bottom line
    public let transcript: [AgentMessage]   // every agent, in order
    public let generatedAt: Date
    /// Compliance line carried with every report. The desk publishes the same
    /// non-personalized analysis to all users → it's market insight, not a
    /// personal recommendation. (MiFID/MAR posture — see project notes.)
    public let disclaimer: String
    /// Provenance of the report — `nil` means the canonical Wicker desk
    /// run, anything else identifies the external author. `wick-mcp`
    /// stamps this with `mcp:<client-name>` (e.g. `mcp:claude-code`) when
    /// `wick.write_report` is called, so the UI can render a small badge
    /// distinguishing "you ran Wicker" from "your agent wrote this back".
    /// Codable-optional → reports written by older builds decode cleanly.
    public let source: String?

    /// Default disclaimer applied to every generated report.
    public static let defaultDisclaimer =
        "AI-generated market analysis for informational purposes only. Not investment "
        + "advice and not a personal recommendation. Do your own research."

    public init(ticker: String, asOf: Date, rating: Rating,
                position: PositionSize? = nil,
                summary: String, transcript: [AgentMessage], generatedAt: Date = .now,
                disclaimer: String = Report.defaultDisclaimer,
                source: String? = nil) {
        self.ticker = ticker
        self.asOf = asOf
        self.rating = rating
        self.position = position
        self.summary = summary
        self.transcript = transcript
        self.generatedAt = generatedAt
        self.disclaimer = disclaimer
        self.source = source
    }
}
