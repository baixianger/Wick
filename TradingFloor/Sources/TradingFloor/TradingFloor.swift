import Foundation

/// The public entry point. Construct it with the user's LLM provider, a
/// market-data source, and a config, then call `analyze`. Everything else in
/// the package is an implementation detail.
///
/// ```swift
/// let desk = TradingFloor(
///     llm: AnthropicProvider(apiKey: key),
///     data: wickDataBridge,          // Wick's MarketDataProvider
///     config: .init(maxDebateRounds: 2)
/// )
/// let report = try await desk.analyze(ticker: "NVDA") { stage in
///     print("…", stage)             // drive a progress label
/// }
/// print(report.rating.label, report.summary)
/// ```
public struct TradingFloor: Sendable {
    public let llm: any LLMProvider
    public let data: any MarketDataProvider
    public let config: TradingFloorConfig
    /// Optional source of prior reports for self-conditioning. If set, the
    /// trader sees its last few calls on the ticker (most recent excluded:
    /// today's run is still in flight). Wire this to the same `ReportStore`
    /// you already pass into `ReportService` so cache + history are aligned.
    public let history: (any ReportStore)?

    public init(llm: any LLMProvider,
                data: any MarketDataProvider,
                config: TradingFloorConfig = .init(),
                history: (any ReportStore)? = nil) {
        self.llm = llm
        self.data = data
        self.config = config
        self.history = history
    }

    /// Run the full desk on one ticker. `onStage` fires as each phase starts,
    /// so the UI can show "Analysts → Debate r1 → Trader → Risk".
    public func analyze(
        ticker: String,
        asOf: Date = .now,
        onStage: (@Sendable (String) -> Void)? = nil
    ) async throws -> Report {
        // Route the desk per-ticker, mirroring how the data layer already
        // auto-routes by symbol. Chinese A-share / HK tickers run the Chinese
        // desk (Chinese prompts + output, CN-specific analysts); everything
        // else keeps the English desk. Same graph, different profile.
        let desk = DeskProfile.forTicker(ticker)
        let ctx = AgentContext(llm: llm, config: config, desk: desk)

        onStage?("Gathering market data")
        let snapshot = try await data.snapshot(symbol: ticker, asOf: asOf)
        let priorReports: [Report]
        if let store = history, config.historyDepth > 0 {
            let today = TradingDay.key(asOf)
            priorReports = await store.recent(
                ticker: ticker, limit: config.historyDepth, excluding: today
            )
        } else {
            priorReports = []
        }
        let state = AgentState(ticker: ticker, asOf: asOf, market: snapshot, history: priorReports)

        // 1. Analysts — independent, so run concurrently, then append in a
        //    stable order for a deterministic transcript.
        onStage?("Analysts at work")
        // Intersect the desk's eligible roster with the user's enabled
        // analysts. The desk roster is the gate that keeps a US run from ever
        // spawning the CN-only policy / capital analysts (the default config
        // enables every AnalystKind); the user's set still trims within it.
        let kinds = desk.analysts.filter { config.analysts.contains($0) }
        let analystMessages = try await withThrowingTaskGroup(
            of: (Int, AgentMessage).self
        ) { group in
            for (i, kind) in kinds.enumerated() {
                // Each task gets its own state built from Sendable values
                // (ticker/date/snapshot). Analysts only read market data, so
                // they don't need the shared, mutating transcript.
                group.addTask {
                    let local = AgentState(ticker: ticker, asOf: asOf, market: snapshot)
                    return (i, try await AnalystAgent(kind).run(local, ctx: ctx))
                }
            }
            var out: [(Int, AgentMessage)] = []
            for try await pair in group { out.append(pair) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        analystMessages.forEach(state.append)

        // 2. Bull/bear debate — sequential, each side reads the running thread.
        // Guard the range explicitly; `1...0` traps even when the `where` clause
        // would skip every iteration, because the range is built first.
        if config.maxDebateRounds > 0 {
            for round in 1...config.maxDebateRounds {
                onStage?("Bull/bear debate, round \(round)")
                state.append(try await ResearcherAgent(.bull).run(state, ctx: ctx))
                state.append(try await ResearcherAgent(.bear).run(state, ctx: ctx))
            }
        }

        // 3. Trader decides.
        onStage?("Trader deciding")
        let tradeMsg = try await TraderAgent().run(state, ctx: ctx)
        state.append(tradeMsg)

        // 4. Risk review.
        onStage?("Risk review")
        state.append(try await RiskAgent().run(state, ctx: ctx))

        // Prefer the trader's typed JSON envelope when present; fall back
        // to the legacy substring parsers so older models / parse misses
        // still produce a valid Report.
        let rating = tradeMsg.rating ?? Rating.parse(tradeMsg.content)
        let position: PositionSize? = {
            if let pct = tradeMsg.positionPercent {
                return PositionSize(targetWeight: pct / 100)
            }
            return PositionSize.parse(tradeMsg.content)
        }()
        return Report(
            ticker: ticker,
            asOf: asOf,
            rating: rating,
            position: position,
            summary: tradeMsg.content,
            transcript: state.transcript,
            disclaimer: desk.locale == .chinese
                ? Report.chineseDisclaimer
                : Report.defaultDisclaimer
        )
    }
}
