import Foundation

/// One of the LLM provider choices a BYO user can pick — plus the
/// special `server` case for the SaaS tier (everything goes through
/// our hosted WickServer, which brokers via OpenRouter).
///
/// The two routes are mutually exclusive at the settings level:
///   - `.server` = SaaS tier. Wick app talks to WickServer; WickServer
///     talks to OpenRouter on our backend. The user does NOT carry an
///     LLM key. (Premium / subscription, gated separately.)
///   - everything else = BYO tier. The app talks directly to the
///     selected provider with the user's own key. No traffic touches
///     our servers.
///
/// Per [[wick-business-model]] both tiers ship; this enum is the
/// single switch the dispatch layer reads (`WickerLLM.provider(for:)`
/// + `DeskRunner.run(...)`).
enum ProviderKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {

    // ── SaaS ──
    case server                      // Wick-hosted (Premium)

    // ── BYO clouds (their own Messages API) ──
    case anthropic                   // Claude family — our own AnthropicProvider

    // ── BYO clouds (OpenAI-compatible) ──
    case openai                      // GPT family
    case openrouter                  // 400+ aggregated models
    case gemini                      // Google, via OpenAI-compat endpoint
    case deepseek                    // DeepSeek
    case xai                         // Grok
    case glm                         // Zhipu 智谱
    case kimi                        // Moonshot
    case minimax                     // MiniMax
    case qwen                        // Alibaba DashScope (compatible mode)

    // ── BYO clouds (catch-all) ──
    case custom                      // Any OpenAI-compatible endpoint

    // ── BYO local ──
    case ollama                      // localhost OpenAI-compatible

    var id: String { rawValue }

    /// Human-readable label for picker rows.
    var displayName: String {
        switch self {
        case .server:     return "Wick Server (managed)"
        case .anthropic:  return "Anthropic"
        case .openai:     return "OpenAI"
        case .openrouter: return "OpenRouter"
        case .gemini:     return "Google Gemini"
        case .deepseek:   return "DeepSeek"
        case .xai:        return "xAI (Grok)"
        case .glm:        return "GLM (Zhipu 智谱)"
        case .kimi:       return "Kimi (Moonshot)"
        case .minimax:    return "MiniMax"
        case .qwen:       return "Qwen (DashScope 阿里)"
        case .custom:     return "Custom (OpenAI-compatible)"
        case .ollama:     return "Local (Ollama)"
        }
    }

    /// Default base URL for this provider. User can override on the
    /// `custom` and `ollama` cases; the others usually shouldn't be
    /// touched but we leave the field editable for proxy users.
    var defaultBaseURL: String {
        switch self {
        case .server:     return "http://localhost:8771"
        case .anthropic:  return "https://api.anthropic.com"
        case .openai:     return "https://api.openai.com/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .gemini:     return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepseek:   return "https://api.deepseek.com"
        case .xai:        return "https://api.x.ai/v1"
        case .glm:        return "https://open.bigmodel.cn/api/paas/v4"
        case .kimi:       return "https://api.moonshot.cn/v1"
        case .minimax:    return "https://api.minimax.chat/v1"
        case .qwen:       return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .custom:     return ""
        case .ollama:     return "http://localhost:11434/v1"
        }
    }

    /// Recommended "quick" model — cheap and fast, used for the data-
    /// gathering analysts and as the fallback model list entry until
    /// `/models` is discovered. Names are accurate as of 2026-05.
    var defaultQuickModel: String {
        switch self {
        case .server:     return ""                                      // server chooses
        case .anthropic:  return "claude-haiku-4-5-20251001"
        case .openai:     return "gpt-5-mini"
        case .openrouter: return "deepseek/deepseek-v4-flash"
        case .gemini:     return "gemini-2.5-flash"
        case .deepseek:   return "deepseek-chat"
        case .xai:        return "grok-4-mini"
        case .glm:        return "glm-4.5-flash"
        case .kimi:       return "moonshot-v1-32k"
        case .minimax:    return "abab6.5-chat"
        case .qwen:       return "qwen-turbo"
        case .custom:     return ""
        case .ollama:     return "llama3.1"
        }
    }

/// Recommended "deep" model — stronger reasoning for the debate /
    /// trader / risk passes and for the Wicker chat. Same names act as
    /// `WickerLLM.model(for:)` defaults until discovery overrides.
    var defaultDeepModel: String {
        switch self {
        case .server:     return ""                                      // server chooses
        case .anthropic:  return "claude-opus-4-7"
        case .openai:     return "gpt-5"
        case .openrouter: return "anthropic/claude-opus-4.7"
        case .gemini:     return "gemini-2.5-pro"
        case .deepseek:   return "deepseek-reasoner"
        case .xai:        return "grok-4"
        case .glm:        return "glm-4.5"
        case .kimi:       return "kimi-k2"
        case .minimax:    return "minimax-text-01"
        case .qwen:       return "qwen-max"
        case .custom:     return ""
        case .ollama:     return "llama3.1"
        }
    }

    /// Whether this provider can be sent a `/models`-style discovery
    /// request to enumerate available models. `.server` is opaque to
    /// the client; `.custom` depends on what the user pointed at; the
    /// rest all expose a listing endpoint.
    var supportsModelListing: Bool {
        switch self {
        case .server:     return false
        case .custom:     return true       // optimistic; user-configurable
        default:          return true
        }
    }

    /// Keychain account name used to store this provider's API key.
    /// One key per provider so switching providers doesn't lose the
    /// other's credentials. Matches the existing
    /// `me.impai.wick.{kind}-key` convention.
    var keychainAccount: String {
        "me.impai.wick.\(rawValue)-key"
    }

    /// Whether this provider needs an API key at all. Local Ollama
    /// runs unauthenticated; our managed `server` mode uses a
    /// subscription token rather than a per-provider LLM key.
    var requiresAPIKey: Bool {
        switch self {
        case .server, .ollama: return false
        default:               return true
        }
    }

    /// Whether to dispatch through `AnthropicProvider` (Messages API)
    /// vs `OpenAICompatibleProvider` (chat/completions). The split
    /// only matters for the actual `LLMProvider` call site — every
    /// other code path treats the providers uniformly.
    var transport: Transport {
        switch self {
        case .anthropic:           return .anthropicMessages
        case .server:              return .wickServer
        default:                   return .openAICompatible
        }
    }

    enum Transport: Hashable, Sendable {
        case anthropicMessages       // direct to api.anthropic.com (Messages API)
        case openAICompatible        // POST <baseURL>/chat/completions
        case wickServer              // POST <baseURL>/chat (our broker, OpenRouter behind)
    }

    /// Picker presentation order — SaaS first, then BYO grouped by
    /// flavour. `allCases` order is fine for an ungrouped picker but
    /// the Settings UI uses this to render the dropdown with section
    /// dividers.
    static let pickerSections: [(title: String, items: [ProviderKind])] = [
        ("Managed",    [.server]),
        ("Direct API", [.anthropic, .openai, .openrouter, .gemini,
                        .deepseek, .xai, .glm, .kimi, .minimax, .qwen]),
        ("Other",      [.custom, .ollama]),
    ]
}

// MARK: - ModelInfo

/// Minimal description of one model exposed by a provider's
/// `/models` endpoint (or our hardcoded default for that provider
/// when discovery hasn't run yet / failed). Identifiable on `id` so
/// SwiftUI pickers iterate cleanly.
struct ModelInfo: Identifiable, Codable, Hashable, Sendable {
    /// The opaque model identifier the provider expects in
    /// `model:` of a chat-completion request.
    let id: String
    /// Display name (vendor-friendly label). For most providers
    /// this is just `id`; OpenRouter and some others ship a richer
    /// human label.
    var displayName: String
    /// Context window in tokens, if the discovery response includes
    /// it. UI shows it as a hint next to the model.
    var contextWindow: Int?
    /// Input pricing per 1M tokens in USD, if known. Used by the
    /// OpenRouter dropdown to surface "is this expensive" at a
    /// glance.
    var inputPricePerMillionUSD: Double?
    var outputPricePerMillionUSD: Double?

    init(id: String,
         displayName: String? = nil,
         contextWindow: Int? = nil,
         inputPricePerMillionUSD: Double? = nil,
         outputPricePerMillionUSD: Double? = nil)
    {
        self.id = id
        self.displayName = displayName ?? id
        self.contextWindow = contextWindow
        self.inputPricePerMillionUSD = inputPricePerMillionUSD
        self.outputPricePerMillionUSD = outputPricePerMillionUSD
    }
}
