import Foundation

/// Data-gathering analyst (quick model). One instance per `AnalystKind`.
public struct AnalystAgent: Agent {
    public let kind: AnalystKind
    public var role: String { "\(kind.rawValue.capitalized) Analyst" }
    public init(_ kind: AnalystKind) { self.kind = kind }

    public func run(_ state: AgentState, ctx: AgentContext) async throws -> AgentMessage {
        let user = """
        \(Prompts.context(state))

        Data for your desk:
        \(state.market.brief(for: kind))
        """
        let text = try await ask(system: Prompts.analyst(kind), user: user, ctx: ctx)
        guard let parsed = parseEnvelope(text) else {
            return AgentMessage(role: role, content: text)
        }
        return AgentMessage(
            role: role, content: text,
            lean: parsed.env.lean.flatMap(Lean.init(rawValue:)),
            headline: parsed.env.headline,
            rating: nil, positionPercent: nil,
            agreesWithTrader: nil, proposedRating: nil,
            body: parsed.body.isEmpty ? nil : parsed.body)
    }
}

/// Bull/bear researchers (deep model). They see the analysts' reports and the
/// running debate transcript.
public struct ResearcherAgent: Agent {
    public enum Side: Sendable { case bull, bear }
    public let side: Side
    public var role: String { side == .bull ? "Bull Researcher" : "Bear Researcher" }
    public var usesDeepModel: Bool { true }
    public init(_ side: Side) { self.side = side }

    public func run(_ state: AgentState, ctx: AgentContext) async throws -> AgentMessage {
        let system = side == .bull ? Prompts.bull : Prompts.bear
        let user = """
        \(Prompts.context(state))

        Desk notes so far:
        \(state.transcriptText())
        """
        let text = try await ask(system: system, user: user, ctx: ctx)
        guard let parsed = parseEnvelope(text) else {
            return AgentMessage(role: role, content: text)
        }
        return AgentMessage(
            role: role, content: text,
            lean: nil,
            headline: parsed.env.headline,
            rating: nil, positionPercent: nil,
            agreesWithTrader: nil, proposedRating: nil,
            body: parsed.body.isEmpty ? nil : parsed.body)
    }
}

/// Final decision-maker (deep model).
public struct TraderAgent: Agent {
    public var role: String { "Trader" }
    public var usesDeepModel: Bool { true }
    public init() {}

    public func run(_ state: AgentState, ctx: AgentContext) async throws -> AgentMessage {
        let historyBlock = Prompts.history(state.history)
        let historySection = historyBlock.isEmpty ? "" : "\n\n\(historyBlock)"
        let user = """
        \(Prompts.context(state))\(historySection)

        Full desk discussion:
        \(state.transcriptText())
        """
        let text = try await ask(system: Prompts.trader, user: user, ctx: ctx)
        guard let parsed = parseEnvelope(text) else {
            return AgentMessage(role: role, content: text)
        }
        return AgentMessage(
            role: role, content: text,
            lean: nil,
            headline: parsed.env.headline,
            rating: parsed.env.rating.flatMap(Rating.fromLabel),
            positionPercent: parsed.env.positionPercent,
            agreesWithTrader: nil, proposedRating: nil,
            body: parsed.body.isEmpty ? nil : parsed.body)
    }
}

/// Sanity check on the trader's call (deep model).
public struct RiskAgent: Agent {
    public var role: String { "Risk Manager" }
    public var usesDeepModel: Bool { true }
    public init() {}

    public func run(_ state: AgentState, ctx: AgentContext) async throws -> AgentMessage {
        let decision = state.latest(from: "Trader") ?? "(no decision)"
        let user = """
        \(Prompts.context(state))

        Trader's decision:
        \(decision)
        """
        let text = try await ask(system: Prompts.risk, user: user, ctx: ctx)
        guard let parsed = parseEnvelope(text) else {
            return AgentMessage(role: role, content: text)
        }
        return AgentMessage(
            role: role, content: text,
            lean: nil,
            headline: parsed.env.headline,
            rating: nil, positionPercent: nil,
            agreesWithTrader: parsed.env.agreesWithTrader,
            proposedRating: parsed.env.proposedRating.flatMap(Rating.fromLabel),
            body: parsed.body.isEmpty ? nil : parsed.body)
    }
}

// MARK: - JSON envelope parsing

/// All fields any agent could put in its JSON header. Codable-optional so
/// each agent only populates the keys relevant to its role; missing keys
/// decode as nil. **Never crashes on extra keys** — `decodeIfPresent`
/// silently ignores them.
struct AgentEnvelope: Decodable {
    let lean: String?
    let headline: String?
    let rating: String?
    let positionPercent: Double?
    let agreesWithTrader: Bool?
    let proposedRating: String?
}

/// Find the first balanced `{ ... }` block in the LLM response and decode
/// it as an `AgentEnvelope`. Returns nil if no valid JSON block is found
/// — caller treats the whole response as free text (legacy behaviour).
///
/// The brace scanner is string-aware (won't trip on `{` inside a string
/// literal) and escape-aware (`\"`, `\\`). This makes it robust against:
///   - LLMs emitting prose BEFORE the JSON ("Here's my analysis: { ... }")
///   - LLMs wrapping the JSON in code fences ("```json\n{...}\n```")
///   - JSON with embedded braces inside string values
///   - Decimal numbers (positionPercent encoded as `15` or `15.0`)
///
/// Returns `(env, body)` where `body` is the text after the closing `}`,
/// trimmed.
func parseEnvelope(_ text: String) -> (env: AgentEnvelope, body: String)? {
    guard let (jsonString, body) = extractJSONBlock(text) else { return nil }
    guard let data = jsonString.data(using: .utf8) else { return nil }
    do {
        let env = try JSONDecoder().decode(AgentEnvelope.self, from: data)
        return (env, body)
    } catch {
        return nil
    }
}

/// Locate the first balanced JSON object in the text. Returns the JSON
/// substring and whatever comes after it (the markdown body), trimmed.
private func extractJSONBlock(_ text: String) -> (json: String, body: String)? {
    guard let firstBrace = text.firstIndex(of: "{") else { return nil }
    var depth = 0
    var idx = firstBrace
    var inString = false
    var escape = false
    while idx < text.endIndex {
        let c = text[idx]
        if escape {
            escape = false
        } else if inString {
            if c == "\\" { escape = true }
            else if c == "\"" { inString = false }
        } else {
            if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let closing = text.index(after: idx)
                    let json = String(text[firstBrace..<closing])
                    let body = String(text[closing...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return (json, body)
                }
            }
        }
        idx = text.index(after: idx)
    }
    return nil
}
