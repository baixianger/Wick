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
    /// account (`me.impai.wick.{kind}-key`), so swapping providers
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
            let account = "me.impai.wick.fmp-key"
            if fmpKey.isEmpty { Keychain.delete(account: account) }
            else { Keychain.save(fmpKey, account: account) }
        }
    }
    var finnhubKey: String {
        didSet {
            let account = "me.impai.wick.finnhub-key"
            if finnhubKey.isEmpty { Keychain.delete(account: account) }
            else { Keychain.save(finnhubKey, account: account) }
        }
    }
    var fredKey: String {
        didSet {
            let account = "me.impai.wick.fred-key"
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
            if serverAuthToken.isEmpty { Keychain.delete(account: "me.impai.wick.server-token") }
            else { Keychain.save(serverAuthToken, account: "me.impai.wick.server-token") }
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
        case .claudeCode:
            // Driven by the locally-installed `claude` CLI + the
            // user's existing subscription auth. No API key, no
            // base URL — if the binary exists we can run. We don't
            // verify the binary here (synchronous fs check would
            // run on every SwiftUI body); the CLI-path field +
            // Test connection button in Settings → MCP cover that.
            return true
        default:
            return !currentAPIKey.isEmpty && !byoBaseURL.isEmpty
        }
    }

    /// Convenience: is there a usable LLM credential on file?
    /// Settings UI uses this to enable/disable the "Refresh models"
    /// button per-provider.
    var hasKey: Bool {
        switch providerKind {
        case .server, .ollama, .claudeCode: return true       // n/a — no key needed
        default:                            return !currentAPIKey.isEmpty
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

    // MARK: - BYO browser-scraping sources (off by default)

    /// Append BYO-cookie 雪球 discussion lines into CN/HK snapshots' `news`
    /// (Mode 1 of the webpage-scraping research doc). **Default FALSE** — the
    /// path is best-effort and requires the user to sign in to 雪球 once in the
    /// in-app browser; it stays inert until both this flag is on AND the session
    /// is valid. CN/HK tickers only; non-CN runs are never touched.
    var enableXueqiuSentiment: Bool {
        didSet { UserDefaults.standard.set(enableXueqiuSentiment, forKey: "tf.enableXueqiuSentiment") }
    }

    /// Give Wicker (the chat agent) browser-operation tools over the embedded
    /// WebKit — navigate / read / snapshot / click / type / eval / fetchJSON
    /// against ANY url, with a LIVE WebView panel that auto-appears in Wicker's
    /// UI while it's driving the page. **Default FALSE** — opt-in. With the flag
    /// OFF, none of the `web.*` tools are registered and the live panel never
    /// shows, so behaviour is exactly as before. The visible live panel + this
    /// flag are the MVP guardrail for the action tools (click / type / eval);
    /// per-action write-confirmation is a hardening follow-up (see `WebTools`).
    /// macOS 26+ only (the `WebPage` API floor) — inert below that even when on.
    var enableWickerBrowser: Bool {
        didSet { UserDefaults.standard.set(enableWickerBrowser, forKey: "tf.enableWickerBrowser") }
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

    /// Path to the `claude` CLI for the `.claudeCode` provider. Empty =
    /// resolve from `$PATH`; non-empty = absolute path the user overrode in
    /// Settings (covers Homebrew variants and pre-release builds).
    var claudeCodeCLIPath: String {
        didSet { UserDefaults.standard.set(claudeCodeCLIPath, forKey: "tf.claudeCodeCLIPath") }
    }

    /// Sidebar / watchlist change pill — show absolute price delta (`+1.23`)
    /// or percent change (`+1.4%`). Same data either way; the picker just
    /// swaps how the number is rendered.
    var watchlistChangeStyle: WatchlistChangeStyle {
        didSet {
            UserDefaults.standard.set(watchlistChangeStyle.rawValue,
                                      forKey: "ui.watchlistChangeStyle")
        }
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

        // One-shot rescue of API keys stored under the previous
        // Keychain schema (no `kSecAttrService`, no
        // `kSecUseDataProtectionKeychain`). Without this, every
        // existing install would silently lose every API key on
        // first launch after the schema tightening landed. Idempotent
        // via a UserDefaults flag — runs once per install. Per-
        // provider accounts + the data-source / server-token slots.
        let perProviderAccounts = ProviderKind.allCases.map(\.keychainAccount)
        Keychain.migrateLegacyEntriesIfNeeded(accounts: perProviderAccounts + [
            "me.impai.wick.fmp-key",
            "me.impai.wick.finnhub-key",
            "me.impai.wick.fred-key",
            "me.impai.wick.server-token",
        ])

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
        self.fmpKey     = Keychain.load(account: "me.impai.wick.fmp-key")     ?? ""
        self.finnhubKey = Keychain.load(account: "me.impai.wick.finnhub-key") ?? ""
        self.fredKey    = Keychain.load(account: "me.impai.wick.fred-key")    ?? ""

        // Server config — independent of provider selection.
        self.serverBaseURL   = ud.string(forKey: "tf.serverBaseURL") ?? "http://localhost:8771"
        self.serverAuthToken = Keychain.load(account: "me.impai.wick.server-token") ?? ""

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
        // Off by default — the BYO 雪球 scraping path is inert until the user
        // opts in (and signs in to 雪球 in the in-app browser).
        self.enableXueqiuSentiment = ud.bool(forKey: "tf.enableXueqiuSentiment")
        // Off by default — Wicker's browser-operation tools + live panel stay
        // inert until the user opts in (and the app is on macOS 26+).
        self.enableWickerBrowser = ud.bool(forKey: "tf.enableWickerBrowser")
        self.userSkillsDirectoryPath = ud.string(forKey: "tf.userSkillsDir")

        self.chartSplitView = ud.bool(forKey: "ui.chartSplitView")
        self.claudeCodeCLIPath = ud.string(forKey: "tf.claudeCodeCLIPath") ?? ""
        self.watchlistChangeStyle = (ud.string(forKey: "ui.watchlistChangeStyle"))
            .flatMap(WatchlistChangeStyle.init(rawValue:)) ?? .absolute
        self.appearanceOverride = (ud.string(forKey: "ui.appearance")).flatMap {
            switch $0 {
            case "dark":  return .dark
            case "light": return .light
            default:      return nil
            }
        }

        // DEBUG-only: opportunistic auto-fill of BYO keys from process
        // environment when Keychain is empty for that slot. Pattern is
        // "scheme/launchd injects env, app prefers it for that one
        // launch and persists to Keychain so the user sees the keys
        // populated in Settings as usual." Release builds skip this
        // entirely so production never picks up unexpected env state.
        //
        // Env var name = the exact name WickServer uses; same set of
        // keys feeds both server and app.
        #if DEBUG
        adoptKeyFromEnvIfMissing()
        #endif
    }

    #if DEBUG
    /// Dev convenience — populate empty Keychain slots from
    /// `ProcessInfo` environment. Mirrors the WickServer launch
    /// convention so a single `.env`-style export feeds both sides
    /// of the stack. Adopting writes the key to Keychain so the
    /// Settings UI shows it filled in (and the user can edit / clear
    /// from there as normal). No-op for any slot that's already set.
    private func adoptKeyFromEnvIfMissing() {
        let env = ProcessInfo.processInfo.environment

        // Data-source keys.
        adopt(env["FRED_API_KEY"]   , current: fredKey)    { fredKey = $0 }
        adopt(env["FINNHUB_API_KEY"], current: finnhubKey) { finnhubKey = $0 }
        adopt(env["FMP_API_KEY"]    , current: fmpKey)     { fmpKey = $0 }

        // Server auth — pick whichever the user wired locally.
        adopt(env["WICK_SERVER_TOKEN"], current: serverAuthToken) { serverAuthToken = $0 }

        // LLM keys — match the provider currently selected so the
        // first BYO key the user might have exported lands in the
        // right slot. Cross-provider env adoption would clobber on
        // every relaunch, which is the opposite of helpful.
        switch providerKind {
        case .anthropic:
            adopt(env["ANTHROPIC_API_KEY"], current: currentAPIKey) { currentAPIKey = $0 }
        case .openrouter:
            adopt(env["OPENROUTER_API_KEY"], current: currentAPIKey) { currentAPIKey = $0 }
        case .openai:
            adopt(env["OPENAI_API_KEY"], current: currentAPIKey) { currentAPIKey = $0 }
        case .gemini:
            adopt(env["GEMINI_API_KEY"] ?? env["GOOGLE_API_KEY"],
                  current: currentAPIKey) { currentAPIKey = $0 }
        case .deepseek:
            adopt(env["DEEPSEEK_API_KEY"], current: currentAPIKey) { currentAPIKey = $0 }
        case .xai:
            adopt(env["XAI_API_KEY"], current: currentAPIKey) { currentAPIKey = $0 }
        case .glm:
            adopt(env["GLM_API_KEY"] ?? env["ZHIPU_API_KEY"],
                  current: currentAPIKey) { currentAPIKey = $0 }
        case .kimi:
            adopt(env["KIMI_API_KEY"] ?? env["MOONSHOT_API_KEY"],
                  current: currentAPIKey) { currentAPIKey = $0 }
        case .minimax:
            adopt(env["MINIMAX_API_KEY"], current: currentAPIKey) { currentAPIKey = $0 }
        case .qwen:
            adopt(env["QWEN_API_KEY"] ?? env["DASHSCOPE_API_KEY"],
                  current: currentAPIKey) { currentAPIKey = $0 }
        case .server, .custom, .ollama, .claudeCode:
            // Server/custom/ollama don't have a canonical env var name —
            // the user sets baseURL by hand. `claudeCode` uses local
            // OAuth, no key at all. Skip.
            break
        }
    }

    /// Assign `candidate` to the slot via the given setter closure when
    /// `current` is empty and `candidate` is a non-empty string.
    ///
    /// **Why a closure instead of `inout`** — the slot properties are
    /// declared on an `@Observable` class. The macro rewrites them
    /// into computed properties whose `_modify` accessor mutates the
    /// backing storage directly and **does not fire the wrapper-level
    /// `didSet`**. Passing the property as `inout` to a helper uses
    /// `_modify`, which silently skips the `Keychain.save(...)` side
    /// effect we depend on for persistence. Direct assignment via the
    /// setter (`currentAPIKey = $0`) DOES fire didSet, so we hand the
    /// setter through a closure here. Mirrors the same trap fixed in
    /// `WatchlistStore`'s `groups` mutations.
    private func adopt(_ candidate: String?,
                       current: String,
                       set: (String) -> Void)
    {
        guard current.isEmpty,
              let v = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !v.isEmpty else { return }
        set(v)
    }
    #endif
}

/// How the watchlist row's change pill renders the day-over-day delta.
/// `.absolute` is the original behavior (`+1.23`), `.percent` mirrors what
/// most trading apps surface (`+1.4%`). Stored as a string in UserDefaults
/// so the value survives across launches.
enum WatchlistChangeStyle: String, CaseIterable, Sendable {
    case absolute
    case percent

    var displayName: String {
        switch self {
        case .absolute: return "Price"
        case .percent:  return "Percent"
        }
    }
}
