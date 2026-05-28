import Foundation
import Observation
import TradingFloor

/// Drives one fixed-flow desk run for the AI tab. Assembles the LLM
/// provider per the user's `providerKind` selection + the cached
/// Yahoo data provider + the TradingFloor pipeline, and exposes a
/// single `phase` the view renders.
@MainActor
@Observable
final class DeskRunner {

    enum Phase {
        case idle
        case running(stage: String)
        case done(Report)
        case failed(String)
    }

    private(set) var phase: Phase = .idle {
        didSet {
            // Persist the last-seen stage label so the workflow
            // stepper can still show which node failed after the
            // runner transitions to `.failed` (which drops the stage
            // from its associated value).
            if case .running(let stage) = phase {
                lastStage = stage
            }
        }
    }

    /// Last stage string observed in a `.running` transition. Persists
    /// across the `.running → .failed` flip so the stepper can mark the
    /// failed phase. Reset to nil only on `reset()`.
    private(set) var lastStage: String?

    /// Optional sink for completed reports. The AI tab passes its
    /// `ReportHistoryStore` so every successful run is preserved across
    /// app launches — that's what makes the "history-first" AI tab
    /// surface possible.
    var onCompleted: ((Report) -> Void)?

    func run(ticker: String, settings: AgentSettings) {
        switch settings.providerKind {
        case .server:
            runViaServer(ticker: ticker, settings: settings)
        case .anthropic:
            runDirect(ticker: ticker,
                       llm: anthropicProvider(settings: settings),
                       config: settings.workflowConfig(),
                       providerName: settings.providerKind.displayName,
                       data: makeMarketData(settings: settings))
        case .claudeCode:
            // Subprocess to the locally-installed `claude` CLI, using the
            // user's existing subscription auth. No API key needed; cost
            // is paid in subscription quota. ~1-2 s extra per call.
            // Empty CLI path → resolve from $PATH (Settings UI tells
            // users this; passing "" to Process.executableURL would
            // instantly fail spawn with a POSIX error).
            runDirect(ticker: ticker,
                       llm: ClaudeCodeProvider(
                            cliPath: settings.claudeCodeCLIPath.isEmpty
                                ? "claude" : settings.claudeCodeCLIPath,
                            mode: .subscription),
                       config: settings.workflowConfig(),
                       providerName: settings.providerKind.displayName,
                       data: makeMarketData(settings: settings))
        default:
            // OpenAI-compatible umbrella (OpenAI / OpenRouter / Gemini /
            // DeepSeek / xAI / GLM / Kimi / MiniMax / Qwen / Custom /
            // Ollama). For Ollama the user's model field likely
            // collapses quick + deep to one endpoint model; for the
            // hosted clouds the per-role split holds.
            runOpenAICompatible(ticker: ticker, settings: settings)
        }
    }

    // MARK: - Dispatch helpers

    private func runViaServer(ticker: String, settings: AgentSettings) {
        guard let base = URL(string: settings.serverBaseURL) else {
            phase = .failed("Invalid server URL.")
            return
        }
        phase = .running(stage: "Contacting server")
        let client = ServerReportClient(baseURL: base)
        Task {
            do {
                let report = try await client.report(ticker: ticker) { stage in
                    Task { @MainActor in self.phase = .running(stage: stage) }
                }
                self.phase = .done(report)
                self.onCompleted?(report)
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Anthropic Messages API direct call.
    private func anthropicProvider(settings: AgentSettings) -> (any LLMProvider)? {
        guard !settings.currentAPIKey.isEmpty else { return nil }
        let baseURL = URL(string: settings.byoBaseURL) ?? URL(string: ProviderKind.anthropic.defaultBaseURL)!
        return AnthropicProvider(apiKey: settings.currentAPIKey, baseURL: baseURL)
    }

    /// Build the data chain from BYO data keys (FMP / Finnhub / FRED).
    /// Same shape as `AgentRuntime.buildMarketData` and
    /// `WickServer.main` — so all three (chat / workflow / server)
    /// see identical snapshots given the same keys.
    private func makeMarketData(settings: AgentSettings) -> any MarketDataProvider {
        AgentRuntime.buildMarketData(from: settings)
    }

    private func runOpenAICompatible(ticker: String, settings: AgentSettings) {
        guard let url = URL(string: settings.byoBaseURL) else {
            phase = .failed("Invalid endpoint URL for \(settings.providerKind.displayName).")
            return
        }
        // Some endpoints (Ollama) skip auth; others require a key. Pass
        // nil rather than an empty string so the provider doesn't add
        // an `Authorization: Bearer ` header.
        let apiKey: String? = settings.providerKind.requiresAPIKey
            ? (settings.currentAPIKey.isEmpty ? nil : settings.currentAPIKey)
            : nil
        if settings.providerKind.requiresAPIKey, apiKey == nil {
            phase = .failed("Add your \(settings.providerKind.displayName) API key first.")
            return
        }
        let llm = OpenAICompatibleProvider(baseURL: url, apiKey: apiKey)
        let config = settings.workflowConfig()
        runDirect(ticker: ticker,
                  llm: llm,
                  config: config,
                  providerName: settings.providerKind.displayName,
                  data: makeMarketData(settings: settings))
    }

    private func runDirect(ticker: String,
                            llm: (any LLMProvider)?,
                            config: TradingFloorConfig,
                            providerName: String,
                            data: any MarketDataProvider)
    {
        guard let llm else {
            phase = .failed("Add your \(providerName) API key first.")
            return
        }
        phase = .running(stage: "Starting")
        let desk = TradingFloor(llm: llm, data: data, config: config)
        Task {
            do {
                let report = try await desk.analyze(ticker: ticker, asOf: .now) { stage in
                    Task { @MainActor in self.phase = .running(stage: stage) }
                }
                self.phase = .done(report)
                self.onCompleted?(report)
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func reset() {
        phase = .idle
        lastStage = nil
    }
}
