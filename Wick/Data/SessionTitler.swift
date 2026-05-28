import Foundation
import TradingFloor

/// Names a `ChatSession` from its first user + assistant turn by
/// calling the configured **lite** model. Cheap (a few hundred
/// tokens at most), runs in the background after the assistant
/// reply lands, and silently no-ops if the user has already
/// renamed the session manually.
///
/// One-shot — no retry, no streaming. If the lite call fails the
/// session keeps the heuristic title `ChatStore` already wrote
/// (first 40 chars of the first user message), which is good
/// enough as a fallback.
@MainActor
enum SessionTitler {

    private static let systemPrompt = """
    You are a chat-session titler. Read the user's first question
    and the assistant's first reply, then return a 3 to 6 word
    title summarising the topic. Output ONLY the title — no quotes,
    no punctuation, no trailing period, no "Title:" prefix.
    """

    /// Build a title for `(userText, assistantText)` using the
    /// lite provider configured in `settings`. Returns nil on any
    /// failure — the caller should fall back to the existing
    /// session title.
    static func makeTitle(userText: String,
                          assistantText: String,
                          settings: AgentSettings) async -> String?
    {
        // Build the same `LLMProvider` Wicker chat uses (Anthropic /
        // OpenAI-compatible umbrella / server), but with the quick
        // model instead of deep. Quick is the cheap "data
        // gathering" tier per [[tradingfloor-agent-design]] —
        // titling a few-word output fits the same cost profile. We
        // collapsed the originally-separate "lite" tier into quick
        // because the only consumer was this titler; one less
        // settings field for the user to think about.
        guard let provider = liteProvider(for: settings) else {
            return nil
        }
        let model = settings.quickModel.isEmpty
            ? settings.providerKind.defaultQuickModel
            : settings.quickModel
        let request = LLMRequest(
            model: model,
            system: systemPrompt,
            messages: [
                LLMMessage(role: .user, content: """
                User: \(userText.prefix(800))
                Assistant: \(assistantText.prefix(800))
                """)
            ],
            maxTokens: 32,
            temperature: 0.4
        )
        do {
            let raw = try await provider.complete(request)
            return cleanTitle(raw)
        } catch {
            return nil
        }
    }

    /// Same dispatch logic as `WickerLLM.provider(for:)` but tied to
    /// the lite model name — kept here so the chat dispatch's
    /// provider build doesn't have to know about session titling.
    private static func liteProvider(for settings: AgentSettings)
        -> (any LLMProvider)?
    {
        switch settings.providerKind {
        case .server:
            guard let base = URL(string: settings.serverBaseURL) else { return nil }
            let url = base.appendingPathComponent("v1")
            let token: String? = settings.serverAuthToken.isEmpty
                ? nil
                : settings.serverAuthToken
            return OpenAICompatibleProvider(baseURL: url, apiKey: token)
        case .anthropic:
            guard !settings.currentAPIKey.isEmpty else { return nil }
            let baseURL = URL(string: settings.byoBaseURL)
                ?? URL(string: ProviderKind.anthropic.defaultBaseURL)!
            return AnthropicProvider(apiKey: settings.currentAPIKey,
                                      baseURL: baseURL)
        case .claudeCode:
            return ClaudeCodeProvider(cliPath: settings.claudeCodeCLIPath,
                                       mode: .subscription)
        default:
            guard let url = URL(string: settings.byoBaseURL) else { return nil }
            let key: String? = settings.providerKind.requiresAPIKey
                ? (settings.currentAPIKey.isEmpty ? nil : settings.currentAPIKey)
                : nil
            if settings.providerKind.requiresAPIKey, key == nil { return nil }
            return OpenAICompatibleProvider(baseURL: url, apiKey: key)
        }
    }

    /// Strip wrapping quotes, trailing punctuation, "Title:" prefix
    /// and clamp to ~50 chars. Some lite models like to wrap the
    /// answer in quotes or prepend "Title:" no matter how clearly
    /// the system prompt forbids it.
    private static func cleanTitle(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leading "Title:" if the model added it anyway.
        if let range = s.range(of: "^(?i:title)\\s*[:：-]\\s*",
                                options: .regularExpression),
           range.lowerBound == s.startIndex
        {
            s.removeSubrange(range)
        }
        // Strip wrapping quotes / smart quotes / backticks.
        let strippableEnds: Set<Character> = ["\"", "“", "”", "'", "‘", "’", "`"]
        if let first = s.first, strippableEnds.contains(first) { s.removeFirst() }
        if let last = s.last, strippableEnds.contains(last) { s.removeLast() }
        // Strip trailing punctuation.
        while let last = s.last,
              last == "." || last == "。" || last == "!" || last == "?"
        {
            s.removeLast()
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Hard cap — session row only shows ~40 chars anyway.
        return String(s.prefix(60))
    }
}
