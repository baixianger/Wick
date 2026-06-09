import Foundation

/// The mutable "blackboard" that flows through the graph. Each agent reads
/// what earlier agents wrote and appends its own message. This is the Swift
/// stand-in for LangGraph's shared state dict — a plain reference type,
/// mutated sequentially by the runner (so no locking needed).
public final class AgentState {
    public let ticker: String
    public let asOf: Date
    public let market: MarketSnapshot
    /// Most-recent-first prior reports for this ticker, optionally pre-loaded
    /// by the runner. Lets the trader condition on its own track record —
    /// live-trade-bench's history-in-prompt trick, used in place of a vector
    /// store / RAG layer.
    public let history: [Report]

    /// Everything said so far, oldest first.
    public private(set) var transcript: [AgentMessage] = []

    public init(ticker: String, asOf: Date, market: MarketSnapshot, history: [Report] = []) {
        self.ticker = ticker
        self.asOf = asOf
        self.market = market
        self.history = history
    }

    public func append(_ message: AgentMessage) { transcript.append(message) }

    /// Convenience: the full transcript rendered for an LLM prompt.
    public func transcriptText() -> String {
        transcript.map { "## \($0.role)\n\($0.content)" }.joined(separator: "\n\n")
    }

    /// The most recent message from a given role, if any.
    public func latest(from role: String) -> String? {
        transcript.last { $0.role == role }?.content
    }
}

/// Everything an agent needs from the outside world. Injected by the runner,
/// so agents stay free of any concrete LLM/data dependency.
public struct AgentContext: Sendable {
    public let llm: any LLMProvider
    public let config: TradingFloorConfig
    /// Which desk this run belongs to — chosen per-ticker by
    /// `TradingFloor.analyze` (English vs Chinese, A-share vs HK). Agents pass
    /// it into `Prompts` so prompt language, report language, and the
    /// market-microstructure note all switch together. Defaults to the English
    /// desk so existing call sites compile unchanged.
    public let desk: DeskProfile

    public init(llm: any LLMProvider, config: TradingFloorConfig,
                desk: DeskProfile = .english) {
        self.llm = llm
        self.config = config
        self.desk = desk
    }
}

/// A node in the desk graph. Implementations are small, single-responsibility
/// structs (one analyst, one researcher, …). `run` reads `state`, calls the
/// LLM via `ctx`, and returns its message; the runner appends it to state.
public protocol Agent: Sendable {
    var role: String { get }
    /// Whether this agent uses the deep-thinking model (debate, risk, trade)
    /// vs the quick model (data-gathering analysts). Maps to TradingAgents'
    /// deep_think_llm / quick_think_llm split.
    var usesDeepModel: Bool { get }
    func run(_ state: AgentState, ctx: AgentContext) async throws -> AgentMessage
}

public extension Agent {
    var usesDeepModel: Bool { false }

    /// Shared helper: build a system+user exchange and return the completion.
    func ask(system: String, user: String, ctx: AgentContext) async throws -> String {
        let model = usesDeepModel ? ctx.config.deepModel : ctx.config.quickModel
        let request = LLMRequest(
            model: model,
            system: system,
            messages: [LLMMessage(role: .user, content: user)],
            maxTokens: ctx.config.maxTokens,
            temperature: ctx.config.temperature
        )
        return try await ctx.llm.complete(request)
    }
}
