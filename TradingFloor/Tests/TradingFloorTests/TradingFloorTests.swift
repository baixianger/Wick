import Testing
import Foundation
@testable import TradingFloor

/// A scripted LLM so the graph can be exercised offline, deterministically.
struct ScriptedLLM: LLMProvider {
    func complete(_ request: LLMRequest) async throws -> String {
        if request.system.contains("Trader") { return "BUY. Momentum and fundamentals align." }
        return "Findings look constructive.\nLean: bullish — improving momentum."
    }
}

@Test func rating_parsing() {
    #expect(Rating.parse("STRONG BUY. ...") == .strongBuy)
    #expect(Rating.parse("we should SELL") == .sell)
    #expect(Rating.parse("unclear") == .hold)
    // Regression: a HOLD verdict whose body mentions "buyback" must not
    // become BUY (word-boundary, first-line-first).
    #expect(Rating.parse("HOLD\n\nThe $80B buyback supports the thesis.") == .hold)
    #expect(Rating.parse("SELL — momentum fading despite the buyback") == .sell)
}

@Test func position_size_parsing() {
    // Canonical shape produced by the trader prompt.
    let pos = PositionSize.parse("BUY\nPosition: 12%\n\nReasoning…")
    #expect(pos?.targetWeight == 0.12)

    // Decimal-fraction variant.
    #expect(PositionSize.parse("STRONG BUY\nALLOC: 0.18")?.targetWeight == 0.18)
    #expect(PositionSize.parse("Target weight: 0.25 (high conviction)")?.targetWeight == 0.25)

    // Long-only clamp to [0, 1].
    #expect(PositionSize.parse("Position: 150%")?.targetWeight == 1.0)

    // Sentence with no position line → nil (older trader outputs).
    #expect(PositionSize.parse("BUY. Momentum and fundamentals align.") == nil)

    // cashWeight is the implicit complement.
    let big = PositionSize(targetWeight: 0.3)
    #expect(abs(big.cashWeight - 0.7) < 1e-9)
}

/// Counts upstream hits so we can prove the cache short-circuits the network.
final class CountingProvider: MarketDataProvider, @unchecked Sendable {
    private(set) var hits = 0
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        hits += 1
        return MarketSnapshot(symbol: symbol, asOf: asOf, lastPrice: 100)
    }
}

@Test func cache_serves_second_call_without_upstream() async throws {
    let upstream = CountingProvider()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tf-cache-\(UUID().uuidString)")
    let cache = CachingMarketDataProvider(wrapping: upstream, ttl: 60, directory: dir)
    let day = Date()
    _ = try await cache.snapshot(symbol: "NVDA", asOf: day)
    _ = try await cache.snapshot(symbol: "NVDA", asOf: day)
    #expect(upstream.hits == 1)   // second call served from cache
}

/// Counts LLM calls so we can prove single-flight collapses many requests
/// into one desk run.
final class CountingLLM: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    func complete(_ request: LLMRequest) async throws -> String {
        lock.withLock { calls += 1 }
        if request.system.contains("Trader") { return "BUY. Momentum aligns." }
        return "Findings constructive.\nLean: bullish."
    }
}

@Test func report_service_single_flight() async throws {
    let llm = CountingLLM()
    let desk = TradingFloor(llm: llm, data: StubMarketDataProvider(),
                            config: .init(maxDebateRounds: 1))
    let service = ReportService(desk: desk, store: InMemoryReportStore())

    // 8 users ask for NVDA at the same instant.
    try await withThrowingTaskGroup(of: Report.self) { group in
        for _ in 0..<8 { group.addTask { try await service.report(ticker: "NVDA") } }
        for try await _ in group {}
    }
    // One run only: 4 analysts + bull + bear + trader + risk = 8 LLM calls,
    // NOT 8×8. Proves the requests collapsed onto a single desk run.
    #expect(llm.calls == 8)

    // A later request is served from cache — no new calls.
    _ = try await service.report(ticker: "NVDA")
    #expect(llm.calls == 8)
}

@Test func report_queue_dedups_and_completes() async throws {
    let llm = CountingLLM()
    let desk = TradingFloor(llm: llm, data: StubMarketDataProvider(),
                            config: .init(maxDebateRounds: 1))
    let queue = ReportQueue(desk: desk, store: InMemoryReportStore(), maxWorkers: 4)

    // 5 users ask for NVDA at once → one job, not five.
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<5 { group.addTask { _ = await queue.submit(ticker: "NVDA") } }
    }
    // Poll until the worker finishes.
    var status = await queue.status(ticker: "NVDA")
    var spins = 0
    while status?.phase != .done, status?.phase != .failed, spins < 200 {
        try await Task.sleep(for: .milliseconds(20))
        status = await queue.status(ticker: "NVDA")
        spins += 1
    }
    #expect(status?.phase == .done)
    #expect(status?.report?.rating == .buy)
    #expect(llm.calls == 8)   // one desk run only — the queue deduped
}

@Test func full_desk_run_produces_report() async throws {
    let desk = TradingFloor(
        llm: ScriptedLLM(),
        data: StubMarketDataProvider(),
        config: .init(maxDebateRounds: 1)
    )
    let report = try await desk.analyze(ticker: "NVDA")
    #expect(report.rating == .buy)
    #expect(report.transcript.contains { $0.role == "Trader" })
    #expect(report.transcript.contains { $0.role == "Risk Manager" })
}

@Test func recent_returns_newest_first_and_excludes_day() async {
    let store = InMemoryReportStore()
    let cal = Calendar(identifier: .gregorian)
    let today = Date()
    for daysAgo in [3, 1, 5, 0, 2] {
        let d = cal.date(byAdding: .day, value: -daysAgo, to: today)!
        let r = Report(ticker: "NVDA", asOf: d, rating: .buy, summary: "BUY", transcript: [])
        await store.save(r, tradingDay: TradingDay.key(d))
    }
    let recent = await store.recent(ticker: "NVDA", limit: 3, excluding: TradingDay.key(today))
    #expect(recent.count == 3)
    // Most recent first, today excluded → 1d, 2d, 3d ago.
    let ages = recent.map { Int(today.timeIntervalSince($0.asOf) / 86_400) }
    #expect(ages == [1, 2, 3])
}

/// Captures the user prompt of each LLM call so we can assert what the
/// trader actually saw.
final class CapturingLLM: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var prompts: [(system: String, user: String)] = []
    func complete(_ request: LLMRequest) async throws -> String {
        let user = request.messages.first?.content ?? ""
        lock.withLock { prompts.append((request.system, user)) }
        if request.system.contains("Trader") {
            return "HOLD\nPosition: 3%\n\nConditions are mixed."
        }
        return "Findings constructive.\nLean: neutral."
    }
}

@Test func tool_call_parser_extracts_fenced_blocks() {
    let reply = """
    Let me check the data.

    ```tool_use
    {"tool": "get_market_data", "arguments": {"symbol": "NVDA"}}
    ```

    Then I'll think.
    """
    let calls = ToolCallParser.parse(reply)
    #expect(calls.count == 1)
    #expect(calls.first?.tool == "get_market_data")
    #expect(calls.first?.argumentsJSON.contains("NVDA") == true)

    let cleaned = ToolCallParser.stripFences(from: reply)
    #expect(!cleaned.contains("tool_use"))
    #expect(cleaned.contains("Let me check"))
}

@Test func tool_call_parser_handles_multiple_calls_and_ignores_malformed() {
    let reply = """
    ```tool_use
    {"tool": "a", "arguments": {}}
    ```
    Text in between.
    ```tool_use
    {NOT JSON
    ```
    ```tool_use
    {"tool": "b", "arguments": {"x": 1}}
    ```
    """
    let calls = ToolCallParser.parse(reply)
    #expect(calls.map(\.tool) == ["a", "b"])
}

/// Tiny scripted tool so we don't need a real provider in the chat-agent
/// test. Just echoes whatever JSON it was given.
struct EchoTool: AgentTool {
    let spec = ToolSpec(
        name: "echo",
        description: "Echoes its arguments back as text.",
        parametersJSONSchema: #"{"type":"object","properties":{"msg":{"type":"string"}}}"#
    )
    func call(arguments: Data) async throws -> String {
        let s = String(data: arguments, encoding: .utf8) ?? "{}"
        return "echo: \(s)"
    }
}

/// Scripts a two-turn exchange: first the model emits a tool_use, second it
/// answers in plain text. Lets us drive the ChatAgent loop end-to-end.
final class ScriptedChatLLM: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var callCount = 0
    func complete(_ request: LLMRequest) async throws -> String {
        lock.withLock { callCount += 1 }
        if callCount == 1 {
            return """
            Checking…
            ```tool_use
            {"tool": "echo", "arguments": {"msg": "hi"}}
            ```
            """
        }
        return "All set — the echo came back."
    }
}

/// Thread-safe event sink — the @Sendable onEvent closure can't capture a
/// `var` directly, so we route through a small lock-guarded class.
final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ChatEvent] = []
    func append(_ e: ChatEvent) { lock.withLock { events.append(e) } }
    var all: [ChatEvent] { lock.withLock { events } }
}

@Test func chat_agent_dispatches_tool_then_answers() async throws {
    let tools = ToolRegistry()
    await tools.register(EchoTool())
    let skills = SkillRegistry()
    await skills.reload()
    let agent = ChatAgent(llm: ScriptedChatLLM(), tools: tools, skills: skills,
                          config: .init(maxDebateRounds: 0))
    var conversation: [LLMMessage] = []
    let sink = EventSink()
    let reply = try await agent.respond(to: "Echo something for me.",
                                        conversation: &conversation) { ev in
        sink.append(ev)
    }
    #expect(reply == "All set — the echo came back.")
    // Loop: user → assistant(tool_use) → user(tool result) → assistant(final).
    #expect(conversation.count == 4)
    let events = sink.all
    #expect(events.contains { if case .toolCall(let n, _) = $0 { return n == "echo" } else { return false } })
    #expect(events.contains { if case .toolResult(let n, _) = $0 { return n == "echo" } else { return false } })
}

@Test func skill_parses_required_fields_and_body() {
    let md = """
    ---
    name: technical-analysis
    description: Analyse price action and indicators.
    triggers: [chart, rsi, macd]
    tools: [get_market_data]
    ---

    # Technical Analysis

    Body text here.
    """
    let skill = Skill.from(markdown: md, source: .bundled)
    #expect(skill?.name == "technical-analysis")
    #expect(skill?.description == "Analyse price action and indicators.")
    #expect(skill?.triggers == ["chart", "rsi", "macd"])
    #expect(skill?.tools == ["get_market_data"])
    #expect(skill?.body.contains("# Technical Analysis") == true)
}

// MARK: - JSON envelope (v2 structured output)

@Test func envelope_parses_clean_analyst_output() {
    let text = """
    {"lean":"bearish","headline":"RSI 90 near 52w high"}

    - Price up 18.6% in 30 days
    - RSI(14) at 90
    """
    let parsed = parseEnvelope(text)
    #expect(parsed?.env.lean == "bearish")
    #expect(parsed?.env.headline == "RSI 90 near 52w high")
    #expect(parsed?.body.contains("Price up 18.6%") == true)
    #expect(parsed?.body.contains("RSI(14)") == true)
}

@Test func envelope_skips_prose_before_json() {
    let text = """
    Here's my analysis:

    {"lean":"bullish","headline":"Margins justify premium"}

    Despite the elevated P/E, services growth supports it.
    """
    let parsed = parseEnvelope(text)
    #expect(parsed?.env.lean == "bullish")
    #expect(parsed?.body.hasPrefix("Despite") == true)
}

@Test func envelope_handles_braces_inside_string_values() {
    // Regression: the brace-balancing scanner must treat `{` inside a
    // string literal as data, not depth. If it didn't, this would close
    // the JSON prematurely at "Threshold {1.5}".
    let text = """
    {"headline":"Threshold {1.5} reached","lean":"bullish"}

    body
    """
    let parsed = parseEnvelope(text)
    #expect(parsed?.env.headline == "Threshold {1.5} reached")
    #expect(parsed?.env.lean == "bullish")
}

@Test func envelope_returns_nil_when_no_json_present() {
    // Pre-v2 LLM output (the cached AAPL / TSLA shape) must fall
    // through cleanly so the legacy substring path takes over.
    #expect(parseEnvelope("Lean: bearish\n\nThe P/E is unsustainable.") == nil)
}

@Test func envelope_parses_trader_fields() {
    let text = """
    {"rating":"HOLD","positionPercent":3,"headline":"Wait for better entry"}

    Mixed conditions suggest sitting out.
    """
    let parsed = parseEnvelope(text)
    #expect(parsed?.env.rating == "HOLD")
    #expect(parsed?.env.positionPercent == 3.0)
    #expect(parsed?.env.headline == "Wait for better entry")
}

@Test func envelope_parses_risk_fields() {
    let text = """
    {"agreesWithTrader":true,"proposedRating":null,"headline":"Sound call"}

    Macro headwinds support caution.
    """
    let parsed = parseEnvelope(text)
    #expect(parsed?.env.agreesWithTrader == true)
    #expect(parsed?.env.proposedRating == nil)
}

@Test func rating_from_label_maps_canonical_strings() {
    #expect(Rating.fromLabel("HOLD")        == .hold)
    #expect(Rating.fromLabel("STRONG SELL") == .strongSell)
    #expect(Rating.fromLabel("Strong-Buy")  == .strongBuy)
    #expect(Rating.fromLabel("garbage")     == nil)
}

// MARK: - Agent ↔ Envelope integration

/// Scripted LLM that returns v2 envelope JSON for every agent role.
final class EnvelopeLLM: LLMProvider, @unchecked Sendable {
    func complete(_ request: LLMRequest) async throws -> String {
        if request.system.contains("Trader") {
            return """
            {"rating":"BUY","positionPercent":12,"headline":"Momentum + fundamentals align"}

            Strong setup — institutional accumulation visible.
            """
        }
        if request.system.contains("Risk Manager") {
            return """
            {"agreesWithTrader":true,"proposedRating":null,"headline":"Sound given evidence"}

            Watch for a hawkish Fed pivot.
            """
        }
        if request.system.contains("Bull Researcher") || request.system.contains("Bear Researcher") {
            return """
            {"headline":"Strongest argument summarized"}

            Specific evidence-based reasoning.
            """
        }
        // Analyst.
        return """
        {"lean":"bullish","headline":"Positive findings"}

        - Revenue accelerating
        - Margins expanding
        """
    }
}

@Test func analyst_run_populates_typed_lean_from_envelope() async throws {
    let agent = AnalystAgent(.fundamental)
    let state = AgentState(
        ticker: "X", asOf: .now,
        market: MarketSnapshot(symbol: "X", asOf: .now, lastPrice: 100))
    let ctx = AgentContext(llm: EnvelopeLLM(), config: .init())
    let msg = try await agent.run(state, ctx: ctx)
    #expect(msg.lean == .bullish)
    #expect(msg.headline == "Positive findings")
    #expect(msg.body?.contains("Revenue accelerating") == true)
}

@Test func trader_run_populates_rating_and_position_from_envelope() async throws {
    let agent = TraderAgent()
    let state = AgentState(
        ticker: "X", asOf: .now,
        market: MarketSnapshot(symbol: "X", asOf: .now, lastPrice: 100))
    let ctx = AgentContext(llm: EnvelopeLLM(), config: .init())
    let msg = try await agent.run(state, ctx: ctx)
    #expect(msg.rating == .buy)
    #expect(msg.positionPercent == 12.0)
    #expect(msg.headline == "Momentum + fundamentals align")
}

@Test func full_desk_uses_envelope_for_report_rating_and_position() async throws {
    let desk = TradingFloor(
        llm: EnvelopeLLM(), data: StubMarketDataProvider(),
        config: .init(maxDebateRounds: 0))
    let report = try await desk.analyze(ticker: "X")
    #expect(report.rating == .buy)                     // from typed envelope
    #expect(report.position?.targetWeight == 0.12)      // 12 → 0.12
    let traderMsg = report.transcript.first { $0.role == "Trader" }
    #expect(traderMsg?.headline == "Momentum + fundamentals align")
}

@Test func full_desk_falls_back_to_text_parsing_for_pre_v2_models() async throws {
    // Older LLM that doesn't emit JSON — Report must still come out
    // valid by routing through Rating.parse / PositionSize.parse.
    let desk = TradingFloor(
        llm: ScriptedLLM(), data: StubMarketDataProvider(),
        config: .init(maxDebateRounds: 0))
    let report = try await desk.analyze(ticker: "X")
    #expect(report.rating == .buy)                     // from Rating.parse
    let traderMsg = report.transcript.first { $0.role == "Trader" }
    #expect(traderMsg?.rating == nil)                  // envelope parse failed → nil
    #expect(traderMsg?.body == nil)                    // envelope parse failed → nil
}

@Test func skill_rejects_files_without_frontmatter() {
    #expect(Skill.from(markdown: "# just a readme", source: .bundled) == nil)
    #expect(Skill.from(markdown: "---\nname: only-name\n---\n", source: .bundled) == nil)
}

@Test func skill_registry_loads_bundled_and_filters_by_trigger() async {
    let registry = SkillRegistry()
    await registry.reload()
    let all = await registry.all()
    #expect(all.contains { $0.name == "technical-analysis" })
    #expect(all.contains { $0.name == "fundamental-analysis" })

    let momentumSkills = await registry.relevant(to: ["momentum"])
    #expect(momentumSkills.contains { $0.name == "technical-analysis" })
    // Sentiment skill doesn't list "momentum" as a trigger → filtered out.
    #expect(!momentumSkills.contains { $0.name == "sentiment-analysis" })
}

@Test func trader_sees_history_when_store_wired() async throws {
    let store = InMemoryReportStore()
    // Seed 2 prior reports for NVDA, on calendar-prior days.
    let cal = Calendar(identifier: .gregorian)
    for daysAgo in [1, 2] {
        let d = cal.date(byAdding: .day, value: -daysAgo, to: .now)!
        let r = Report(ticker: "NVDA", asOf: d, rating: .buy,
                       position: PositionSize(targetWeight: 0.1),
                       summary: "BUY", transcript: [])
        await store.save(r, tradingDay: TradingDay.key(d))
    }
    let llm = CapturingLLM()
    let desk = TradingFloor(
        llm: llm, data: StubMarketDataProvider(),
        config: .init(maxDebateRounds: 0, historyDepth: 5),
        history: store
    )
    _ = try await desk.analyze(ticker: "NVDA")

    // Find the trader's user prompt and assert it contains the history block.
    let traderPrompt = llm.prompts.first { $0.system.contains("Trader") }?.user ?? ""
    #expect(traderPrompt.contains("Your prior calls on this ticker"))
    #expect(traderPrompt.contains("Buy"))
    #expect(traderPrompt.contains("position 10%"))
}
