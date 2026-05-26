import Foundation

/// A working Anthropic Messages API provider. Uses the user's own API key,
/// so token cost stays with the user — the single most important property
/// for shipping an agentic feature without underwriting everyone's spend.
///
/// `baseURL` is overridable so the same struct can target an
/// Anthropic-compatible gateway. For OpenAI / Ollama / OpenRouter you'd add
/// a sibling provider with the same protocol conformance.
public struct AnthropicProvider: LLMProvider {
    public let apiKey: String
    public let baseURL: URL
    public let session: URLSession

    public init(apiKey: String,
                baseURL: URL = URL(string: "https://api.anthropic.com")!,
                session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = Body(
            model: request.model,
            max_tokens: request.maxTokens,
            temperature: request.temperature,
            system: request.system,
            messages: request.messages.map { .init(role: $0.role.rawValue, content: $0.content) }
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.transport("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(status: http.statusCode,
                                body: String(data: data, encoding: .utf8) ?? "")
        }

        do {
            let decoded = try JSONDecoder().decode(Reply.self, from: data)
            let text = decoded.content.compactMap { $0.text }.joined()
            guard !text.isEmpty else { throw LLMError.empty }
            return text
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Wire types

    private struct Body: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let max_tokens: Int
        let temperature: Double
        let system: String
        let messages: [Message]
    }

    private struct Reply: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
    }
}
