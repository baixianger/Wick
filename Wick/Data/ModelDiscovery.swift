import Foundation

/// Pulls the list of available models off a provider's discovery
/// endpoint so the Settings UI can populate Quick/Deep model
/// dropdowns instead of asking the user to type model IDs.
///
/// Three concrete shapes:
///   - `OpenAICompatibleModelDiscovery`: `GET <baseURL>/models`
///     returning `{ data: [{ id, ... }] }` — covers 10 providers
///     (OpenAI / OpenRouter / Gemini's OAI-compat endpoint /
///     DeepSeek / xAI / GLM / Kimi / MiniMax / Qwen / Custom)
///   - `AnthropicModelDiscovery`: `GET /v1/models` with the
///     Anthropic-specific schema (`{ data: [{ id, display_name,
///     created_at }] }`)
///   - `OllamaModelDiscovery`: `GET <host>/api/tags` returning
///     `{ models: [{ name, ... }] }` — Ollama deliberately doesn't
///     conform to OpenAI's `/models` path so we need a special
///     case
///
/// All three return the same `[ModelInfo]` so the consumer
/// (Settings UI) is provider-agnostic.

protocol ModelDiscovery: Sendable {
    /// Fetch the model list. `apiKey` is optional because Ollama and
    /// some private OpenAI-compat endpoints don't need one.
    func listModels(baseURL: URL,
                    apiKey: String?) async throws -> [ModelInfo]
}

enum ModelDiscoveryError: Error, LocalizedError {
    case badURL
    case http(status: Int, body: String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .badURL:                return "Invalid base URL."
        case .http(let s, let b):    return "HTTP \(s): \(b.prefix(160))"
        case .decoding(let m):       return "Couldn't decode response: \(m)"
        case .transport(let m):      return "Network: \(m)"
        }
    }
}

/// Top-level factory — picks the right discovery impl for the
/// provider. Internal-only; the Settings UI uses
/// `ProviderDiscovery.fetchModels(for: kind, baseURL: url, apiKey: k)`.
enum ProviderDiscovery {
    @MainActor
    static func fetchModels(for kind: ProviderKind,
                             baseURL: URL,
                             apiKey: String?) async throws -> [ModelInfo]
    {
        let discovery: any ModelDiscovery
        switch kind {
        case .anthropic:
            discovery = AnthropicModelDiscovery()
        case .ollama:
            discovery = OllamaModelDiscovery()
        case .server:
            // Server tier — model selection happens server-side;
            // the client never picks. Empty list signals "no UI".
            return []
        case .codex:
            // Local presets, as in pi-ai's provider catalog; not an account entitlement check.
            return [ModelInfo(id: "gpt-5.6-sol"), ModelInfo(id: "gpt-5.6-terra"),
                    ModelInfo(id: "gpt-5.6-luna"), ModelInfo(id: "gpt-5.5")]
        case .claudeCode:
            // No discovery endpoint — Claude Code accepts any model the
            // user is entitled to on their subscription. The static
            // default (`claude-haiku-4-5-20251001` / `claude-opus-4-7`)
            // is good enough; advanced users can override in Settings.
            return [
                ModelInfo(id: "claude-haiku-4-5-20251001",
                          displayName: "Claude Haiku 4.5"),
                ModelInfo(id: "claude-sonnet-4-6",
                          displayName: "Claude Sonnet 4.6"),
                ModelInfo(id: "claude-opus-4-7",
                          displayName: "Claude Opus 4.7"),
            ]
        default:
            discovery = OpenAICompatibleModelDiscovery()
        }
        return try await discovery.listModels(baseURL: baseURL,
                                               apiKey: apiKey)
    }
}

// MARK: - OpenAI-compatible (the majority)

struct OpenAICompatibleModelDiscovery: ModelDiscovery {

    private struct Envelope: Decodable {
        let data: [Entry]
    }
    private struct Entry: Decodable {
        let id: String
        // OpenRouter-specific extras — all optional so the same
        // decoder handles plain OpenAI responses too.
        let name: String?
        let context_length: Int?
        let pricing: Pricing?
    }
    private struct Pricing: Decodable {
        // OpenRouter ships prices as $-per-token strings; convert to
        // $-per-million for friendlier UI.
        let prompt: String?
        let completion: String?
    }

    func listModels(baseURL: URL, apiKey: String?) async throws -> [ModelInfo] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)",
                              forHTTPHeaderField: "Authorization")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ModelDiscoveryError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ModelDiscoveryError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelDiscoveryError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            return envelope.data.map { entry in
                ModelInfo(
                    id: entry.id,
                    displayName: entry.name ?? entry.id,
                    contextWindow: entry.context_length,
                    inputPricePerMillionUSD: Self.priceToMillion(entry.pricing?.prompt),
                    outputPricePerMillionUSD: Self.priceToMillion(entry.pricing?.completion))
            }
        } catch {
            throw ModelDiscoveryError.decoding(error.localizedDescription)
        }
    }

    /// OpenRouter ships prices as $-per-input-token strings like
    /// "0.0000015"; we want $-per-million for display ("$1.50/M"). Nil
    /// in / nil out.
    private static func priceToMillion(_ s: String?) -> Double? {
        guard let s, let v = Double(s) else { return nil }
        return v * 1_000_000
    }
}

// MARK: - Anthropic

struct AnthropicModelDiscovery: ModelDiscovery {

    private struct Envelope: Decodable {
        let data: [Entry]
    }
    private struct Entry: Decodable {
        let id: String
        let display_name: String?
    }

    func listModels(baseURL: URL, apiKey: String?) async throws -> [ModelInfo] {
        guard let apiKey, !apiKey.isEmpty else {
            throw ModelDiscoveryError.http(status: 401,
                                           body: "Anthropic requires an API key.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ModelDiscoveryError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ModelDiscoveryError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelDiscoveryError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            return envelope.data.map {
                ModelInfo(id: $0.id, displayName: $0.display_name ?? $0.id)
            }
        } catch {
            throw ModelDiscoveryError.decoding(error.localizedDescription)
        }
    }
}

// MARK: - Ollama

struct OllamaModelDiscovery: ModelDiscovery {

    private struct Envelope: Decodable {
        let models: [Entry]
    }
    private struct Entry: Decodable {
        let name: String
        let size: Int?           // bytes; ignored in UI
    }

    /// Ollama's listing endpoint lives at `/api/tags`, NOT
    /// `/v1/models`. The `baseURL` consumers pass uses the OAI-style
    /// `/v1` suffix — strip it before tacking on `/api/tags`.
    func listModels(baseURL: URL, apiKey: String?) async throws -> [ModelInfo] {
        var components = URLComponents(url: baseURL,
                                        resolvingAgainstBaseURL: false)
        // Walk back from `…/v1` to the root, then append `/api/tags`.
        let trimmedPath = components?.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "v1", with: "") ?? ""
        components?.path = "/" + trimmedPath + "api/tags"
        guard let url = components?.url else {
            throw ModelDiscoveryError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ModelDiscoveryError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ModelDiscoveryError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelDiscoveryError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            return envelope.models.map { ModelInfo(id: $0.name) }
        } catch {
            throw ModelDiscoveryError.decoding(error.localizedDescription)
        }
    }
}
