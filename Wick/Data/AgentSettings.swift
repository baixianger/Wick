import Foundation
import Observation
import SwiftUI
import TradingFloor

/// App-wide settings for everything user-tunable. Two tiers per
/// [[wick-business-model]]:
///
///   - **BYO** (`providerKind != .server`) — Wick talks directly to
///     the user's chosen LLM provider with their own key. No traffic
///     touches our servers. 10+ providers supported (Anthropic /
///     OpenAI / OpenRouter / Gemini / DeepSeek / xAI / GLM / Kimi /
///     MiniMax / Qwen / Ollama / Custom).
///   - **Server / SaaS** (`providerKind == .server`) — Wick talks
///     to our hosted WickServer, which brokers via OpenRouter on
///     our backend. User carries a subscription token, not an LLM
///     key. (Premium tier.)
///
/// Keys live in Keychain (one account per provider, so switching
/// providers doesn't lose your other credentials). Everything else
/// in UserDefaults. Injected via the environment so any view can
/// read or bind.
@MainActor
@Observable
final class AgentSettings {

    // MARK: - Provider selection (the single switch)

    /// Which provider to dispatch all LLM traffic through. `.server`
    /// = SaaS tier; everything else = BYO. The Settings UI's
    /// "Provider" tab is the only place this is set.
    var providerKind: ProviderKind {
        didSet {
            UserDefaults.standard.set(providerKind.rawValue, forKey: "tf.providerKind")
            // Refresh in-memory key + per-provider config when the
            // user switches providers. Keys are kept in Keychain
            // per-provider; we reload whichever one is now active.
            currentAPIKey = Keychain.load(account: providerKind.keychainAccount) ?? ""
            if byoBaseURL.isEmpty || oldValue != providerKind {
                // Auto-fill the base URL on provider change so a fresh
                // switch lands on sensible defaults; the user can edit
                // afterwards.
                byoBaseURL = providerKind.defaultBaseURL
            }
            if quickModel.isEmpty || oldValue != providerKind {
                quickModel = providerKind.defaultQuickModel
            }
            if deepModel.isEmpty || oldValue != providerKind {
                deepModel = providerKind.defaultDeepModel
            }
        }
    }

    // MARK: - BYO config (active when providerKind != .server)

    /// The API key for the CURRENTLY-SELECTED `providerKind`. Mirrored
    /// to the Keychain on every change under that provider's own
    /// account (`ai.omika.wick.{kind}-key`), so swapping providers
    /// preserves all the other keys.
    var currentAPIKey: String {
        didSet {
            let account = providerKind.keychainAccount
            if currentAPIKey.isEmpty { Keychain.delete(account: account) }
            else { Keychain.save(currentAPIKey, account: account) }
        }
    }

    /// Base URL for the BYO provider. Auto-filled to
    /// `providerKind.defaultBaseURL` on provider switch; user can
    /// override for proxies or self-hosted endpoints.
    var byoBaseURL: String {
        didSet { UserDefaults.standard.set(byoBaseURL, forKey: "tf.byo.\(providerKind.rawValue).baseURL") }
    }

    /// Fast model for the data-gathering analysts.
    var quickModel: String {
        didSet { UserDefaults.standard.set(quickModel, forKey: "tf.byo.\(providerKind.rawValue).quickModel") }
    }

    /// Strong model for debate / trade / risk reasoning + Wicker chat.
    var deepModel: String {
        didSet { UserDefaults.standard.set(deepModel, forKey: "tf.byo.\(providerKind.rawValue).deepModel") }
    }

    /// Cached list of models discovered from this provider's `/models`
    /// endpoint, if the user has refreshed. Empty = fall back to the
    /// hardcoded recommended defaults in the UI dropdowns.
    var availableModels: [ModelInfo] {
        didSet {
            // Only the current provider's discoveries are cached —
            // each provider gets its own bucket via the key.
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(availableModels) {
                UserDefaults.standard.set(data, forKey: "tf.byo.\(providerKind.rawValue).availableModels")
            }
        }
    }

    // MARK: - Data-source keys (BYO tier only — server tier uses our
    // env-var keys on the server side)
    //
    // Per [[wick-business-model]] the BYO promise is "users supply
    // ALL data API keys + LLM key". These three drive the same
    // FMP → Finnhub → FRED decorator chain WickServer assembles
    // for the server tier; each key is independently optional and
    // each gets its own Keychain account so a partial setup (e.g.
    // FRED but no FMP) is fine.
    var fmpKey: String {
        didSet {
            let account = "ai.omika.wick.fmp-key"
            if fmpKey.isEmpty { Keychain.delete(account: account) }
            else { Keychain.save(fmpKey, account: account) }
        }
    }
    var finnhubKey: String {
        didSet {
            let account = "ai.omika.wick.finnhub-key"
            if finnhubKey.isEmpty { Keychain.delete(account: account) }
            else { Keychain.save(finnhubKey, account: account) }
        }
    }
    var fredKey: String {
        didSet {
            let account = "ai.omika.wick.fred-key"
            if fredKey.isEmpty { Keychain.delete(account: account) }
            else { Keychain.save(fredKey, account: account) }
        }
    }

    // MARK: - Server / SaaS config (active when providerKind == .server)

    var serverBaseURL: String {
        didSet { UserDefaults.standard.set(serverBaseURL, forKey: "tf.serverBaseURL") }
    }
    /// Placeholder for the subscription / Sign-In-with-Apple token
    /// our server will require once auth is wired. Empty for now —
    /// server runs unauthenticated against `localhost:8771` during
    /// development.
    var serverAuthToken: String {
        didSet {
            if serverAuthToken.isEmpty { Keychain.delete(account: "ai.omika.wick.server-token") }
            else { Keychain.save(serverAuthToken, account: "ai.omika.wick.server-token") }
        }
    }

    // MARK: - Derived gates

    /// Can a run start? Server mode needs a URL; BYO needs a key for
    /// providers that require one (Ollama is keyless, server uses
    /// its own token).
    var canRun: Bool {
        switch providerKind {
        case .server:
            return !serverBaseURL.isEmpty
        case .ollama:
            return !byoBaseURL.isEmpty
        default:
            return !currentAPIKey.isEmpty && !byoBaseURL.isEmpty
        }
    }

    /// Convenience: is there a usable LLM credential on file?
    /// Settings UI uses this to enable/disable the "Refresh models"
    /// button per-provider.
    var hasKey: Bool {
        switch providerKind {
        case .server, .ollama: return true       // n/a — no key needed
        default:               return !currentAPIKey.isEmpty
        }
    }

    // MARK: - Workflow agent knobs (drives TradingFloor.analyze)

    var analysts: Set<AnalystKind> {
        didSet {
            let raws = analysts.map(\.rawValue).sorted()
            UserDefaults.standard.set(raws, forKey: "tf.analysts")
        }
    }
    var maxDebateRounds: Int {
        didSet { UserDefaults.standard.set(maxDebateRounds, forKey: "tf.maxDebateRounds") }
    }
    var historyDepth: Int {
        didSet { UserDefaults.standard.set(historyDepth, forKey: "tf.historyDepth") }
    }
    var temperature: Double {
        didSet { UserDefaults.standard.set(temperature, forKey: "tf.temperature") }
    }

    // MARK: - Free agent knobs

    var freeAgentMaxToolTurns: Int {
        didSet { UserDefaults.standard.set(freeAgentMaxToolTurns, forKey: "tf.freeAgentTurns") }
    }

    // MARK: - Skills (user-supplied playbooks)

    var userSkillsDirectoryPath: String? {
        didSet {
            if let path = userSkillsDirectoryPath, !path.isEmpty {
                UserDefaults.standard.set(path, forKey: "tf.userSkillsDir")
            } else {
                UserDefaults.standard.removeObject(forKey: "tf.userSkillsDir")
            }
        }
    }
    var userSkillsDirectoryURL: URL? {
        userSkillsDirectoryPath.flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: - Display

    var chartSplitView: Bool {
        didSet { UserDefaults.standard.set(chartSplitView, forKey: "ui.chartSplitView") }
    }

    var appearanceOverride: ColorScheme? {
        didSet {
            let raw: String? = appearanceOverride.map { $0 == .dark ? "dark" : "light" }
            if let raw { UserDefaults.standard.set(raw, forKey: "ui.appearance") }
            else { UserDefaults.standard.removeObject(forKey: "ui.appearance") }
        }
    }

    // MARK: - Derived config

    /// Compose a `TradingFloorConfig` from the persisted knobs.
    func workflowConfig(quickModelOverride: String? = nil,
                        deepModelOverride: String? = nil) -> TradingFloorConfig {
        TradingFloorConfig(
            quickModel: quickModelOverride ?? quickModel,
            deepModel: deepModelOverride ?? deepModel,
            maxDebateRounds: maxDebateRounds,
            maxTokens: 1500,
            temperature: temperature,
            analysts: analysts,
            historyDepth: historyDepth
        )
    }

    init() {
        let ud = UserDefaults.standard

        // Provider selection — default to Anthropic for first-launch
        // BYO experience (matches the recommended onboarding wizard).
        let kindRaw = ud.string(forKey: "tf.providerKind") ?? ProviderKind.anthropic.rawValue
        let kind = ProviderKind(rawValue: kindRaw) ?? .anthropic
        self.providerKind = kind

        // Per-provider BYO config — each provider has its own bucket
        // of keys (keychain), base URL (UserDefaults), and model
        // strings (UserDefaults), so swapping providers preserves
        // every other provider's setup.
        self.currentAPIKey = Keychain.load(account: kind.keychainAccount) ?? ""
        self.byoBaseURL    = ud.string(forKey: "tf.byo.\(kind.rawValue).baseURL")    ?? kind.defaultBaseURL
        self.quickModel    = ud.string(forKey: "tf.byo.\(kind.rawValue).quickModel") ?? kind.defaultQuickModel
        self.deepModel     = ud.string(forKey: "tf.byo.\(kind.rawValue).deepModel")  ?? kind.defaultDeepModel
        if let data = ud.data(forKey: "tf.byo.\(kind.rawValue).availableModels"),
           let decoded = try? JSONDecoder().decode([ModelInfo].self, from: data)
        {
            self.availableModels = decoded
        } else {
            self.availableModels = []
        }

        // Data-source keys (BYO tier).
        self.fmpKey     = Keychain.load(account: "ai.omika.wick.fmp-key")     ?? ""
        self.finnhubKey = Keychain.load(account: "ai.omika.wick.finnhub-key") ?? ""
        self.fredKey    = Keychain.load(account: "ai.omika.wick.fred-key")    ?? ""

        // Server config — independent of provider selection.
        self.serverBaseURL   = ud.string(forKey: "tf.serverBaseURL") ?? "http://localhost:8771"
        self.serverAuthToken = Keychain.load(account: "ai.omika.wick.server-token") ?? ""

        // Workflow knobs — default to "all analysts, 1 debate round".
        if let raws = ud.array(forKey: "tf.analysts") as? [String] {
            self.analysts = Set(raws.compactMap(AnalystKind.init(rawValue:)))
        } else {
            self.analysts = Set(AnalystKind.allCases)
        }
        self.maxDebateRounds = ud.object(forKey: "tf.maxDebateRounds") as? Int ?? 1
        self.historyDepth    = ud.object(forKey: "tf.historyDepth")    as? Int ?? 5
        self.temperature     = ud.object(forKey: "tf.temperature")     as? Double ?? 0.7

        self.freeAgentMaxToolTurns = ud.object(forKey: "tf.freeAgentTurns") as? Int ?? 6
        self.userSkillsDirectoryPath = ud.string(forKey: "tf.userSkillsDir")

        self.chartSplitView = ud.bool(forKey: "ui.chartSplitView")
        self.appearanceOverride = (ud.string(forKey: "ui.appearance")).flatMap {
            switch $0 {
            case "dark":  return .dark
            case "light": return .light
            default:      return nil
            }
        }
    }
}
