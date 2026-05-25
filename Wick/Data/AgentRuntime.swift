import Foundation
import Observation
import TradingFloor

/// Process-wide registry of `AgentTool`s + `Skill`s that the chat agent
/// (Wicker) and the workflow agent (`TradingFloor.analyze`) both
/// consult. Hosted at app level and injected via the environment so
/// any view that wants to instantiate a `ChatAgent` can read the
/// shared registries off `Environment(AgentRuntime.self)` without
/// rebuilding them per turn.
///
/// Market data provider is constructed from `AgentSettings` (BYO data
/// keys) — mirrors the exact decorator chain `WickServer.main`
/// assembles for the server tier, so BYO and server-mode users get
/// the same data shape into the agents:
///
///   FMPMarketDataProvider (or Yahoo fallback if no FMP key)
///     └─ FinnhubNewsProvider decorator   (if Finnhub key set)
///         └─ FredMacroProvider decorator (if FRED key set)
///             └─ wrapped in CachingMarketDataProvider (15-min TTL)
///
/// Tools are re-registered with the current provider whenever
/// `reconfigure(with:)` fires — host calls that on launch + on every
/// data-key change in Settings.
@MainActor
@Observable
final class AgentRuntime {

    let tools: ToolRegistry
    let skills: SkillRegistry

    init() {
        self.tools = ToolRegistry()
        let userSkillsDir = Self.userSkillsDirectory()
        self.skills = SkillRegistry(userDirectory: userSkillsDir)

        // Initial registration with the Yahoo-only baseline. The host
        // calls `reconfigure(with:)` once `AgentSettings` is available
        // to replace this with the full BYO chain.
        let baseline: any MarketDataProvider =
            CachingMarketDataProvider(wrapping: WickMarketDataProvider(), ttl: 900)
        Task { [tools, skills] in
            await tools.registerAll([
                MarketDataTool(data: baseline),
                SocialSentimentTool(
                    providers: [StubSocialSentimentProvider()],
                    interactive: true),
            ])
            await skills.reload()
        }
    }

    /// Rebuild the market data chain from the user's current data keys
    /// and re-register the tools. ToolRegistry's `register(_:)` is
    /// keyed by `tool.spec.name`, so re-registering with the same
    /// name overwrites the previous tool — no leak, no duplicate.
    func reconfigure(with settings: AgentSettings) {
        let provider = Self.buildMarketData(from: settings)
        Task { [tools] in
            await tools.register(MarketDataTool(data: provider))
        }
    }

    /// Build the full FMP → Finnhub → FRED chain that mirrors
    /// `WickServer.main`. Each decorator is opt-in: missing keys
    /// degrade gracefully (Yahoo fallback for base, empty news /
    /// macro for the decorators). Caching wrapper sits at the
    /// outermost layer.
    static func buildMarketData(from settings: AgentSettings) -> any MarketDataProvider {
        // Base layer: FMP if key set, otherwise Yahoo (no-key
        // baseline).
        var data: any MarketDataProvider = settings.fmpKey.isEmpty
            ? WickMarketDataProvider()
            : FMPMarketDataProvider(apiKey: settings.fmpKey)
        // Finnhub news decorator.
        if !settings.finnhubKey.isEmpty {
            data = FinnhubNewsProvider(
                base: data,
                finnhub: FinnhubClient(apiKey: settings.finnhubKey))
        }
        // FRED macro decorator.
        if !settings.fredKey.isEmpty {
            data = FredMacroProvider(
                base: data,
                fred: FredClient(apiKey: settings.fredKey))
        }
        // Outermost: caching wrapper. 15-min TTL matches DeskRunner.
        return CachingMarketDataProvider(wrapping: data, ttl: 900)
    }

    /// Build a fresh `ChatAgent` for one user turn. Re-built per call
    /// so an `AgentSettings` change between turns (provider switch,
    /// model swap) takes effect immediately. The conversation lives
    /// in `ChatStore`, not on the agent.
    func makeChatAgent(llm: any LLMProvider,
                       config: TradingFloorConfig) -> ChatAgent
    {
        ChatAgent(llm: llm,
                  tools: tools,
                  skills: skills,
                  config: config)
    }

    private static func userSkillsDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true)
        else { return nil }
        let dir = base
            .appendingPathComponent("Wick", isDirectory: true)
            .appendingPathComponent("Skills", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
