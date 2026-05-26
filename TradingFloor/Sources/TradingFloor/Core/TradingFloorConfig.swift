import Foundation

/// Run-time knobs, mirroring TradingAgents' default_config. The two model
/// fields are the "quick vs deep" split: cheap model for data-gathering
/// analysts, stronger model for debate / trading / risk reasoning.
public struct TradingFloorConfig: Sendable {
    /// Model id for fast, shallow tasks (the analysts).
    public var quickModel: String
    /// Model id for deep reasoning (debate, trader, risk).
    public var deepModel: String
    /// How many bull↔bear exchanges to run. 0 skips the debate entirely.
    public var maxDebateRounds: Int
    public var maxTokens: Int
    public var temperature: Double
    /// Which analysts to include. Lets the UI offer a "depth" slider.
    public var analysts: Set<AnalystKind>
    /// How many prior reports for the same ticker to inject into the trader
    /// prompt (history-in-prompt self-conditioning, à la live-trade-bench).
    /// 0 disables the feature even when a history store is attached.
    public var historyDepth: Int

    public init(
        quickModel: String = "claude-haiku-4-5-20251001",
        deepModel: String = "claude-opus-4-7",
        maxDebateRounds: Int = 1,
        maxTokens: Int = 1500,
        temperature: Double = 0.7,
        analysts: Set<AnalystKind> = Set(AnalystKind.allCases),
        historyDepth: Int = 5
    ) {
        self.quickModel = quickModel
        self.deepModel = deepModel
        self.maxDebateRounds = maxDebateRounds
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.analysts = analysts
        self.historyDepth = historyDepth
    }
}

public enum AnalystKind: String, Sendable, CaseIterable, Codable {
    case fundamental, technical, sentiment, news
}
