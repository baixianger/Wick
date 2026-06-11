import Foundation

/// Talks to any OpenAI-compatible `/chat/completions` endpoint. One provider
/// covers a lot of ground behind the same seam:
///
/// - **Ollama** (`http://localhost:11434/v1`) — free, on-device, no key. The
///   recommended "costs nothing" path; reachable over localhost HTTP, which a
///   sandboxed app can do (unlike spawning a CLI).
/// - **LM Studio / LiteLLM / any local proxy** — same shape.
/// - Any hosted OpenAI-compatible service (set `baseURL` + `apiKey`).
///
/// Because it's just an HTTP endpoint, Wick stays agnostic about what's behind
/// it. If a user chooses to run some local proxy there, that's their call —
/// Wick isn't bridging anything specific.
public struct OpenAICompatibleProvider: LLMProvider {
    public let baseURL: URL
    public let apiKey: String?
    public let session: URLSession

    /// - Parameters:
    ///   - baseURL: the API root, e.g. `http://localhost:11434/v1`.
    ///   - apiKey: bearer token if the endpoint needs one; omit for Ollama.
    public init(baseURL: URL, apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    /// Convenience for a local Ollama install.
    public static func ollama(model host: URL = URL(string: "http://localhost:11434/v1")!) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(baseURL: host, apiKey: nil)
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        // Free / shared models throttle hard (429) and occasionally 5xx.
        // Retry with linear backoff so a concurrent burst of agents succeeds.
        var attempt = 0
        while true {
            do { return try await send(request) }
            catch let LLMError.http(status, body) where (status == 429 || status >= 500) && attempt < 5 {
                attempt += 1
                _ = body
                try? await Task.sleep(for: .seconds(Double(attempt) * 2))
            }
        }
    }

    private func send(_ request: LLMRequest) async throws -> String {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        // OpenAI puts the system prompt as a leading message with role "system".
        var messages: [Body.Message] = [.init(role: "system", content: request.system)]
        messages += request.messages.map { .init(role: $0.role.rawValue, content: $0.content) }

        let body = Body(model: request.model, messages: messages,
                        max_tokens: request.maxTokens, temperature: request.temperature)
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw LLMError.transport("Non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let decoded = try JSONDecoder().decode(Reply.self, from: data)
            let msg = decoded.choices.first?.message
            // `content` is OPTIONAL: reasoning models (DeepSeek, etc.) often
            // return `content: null` and put the answer in `reasoning_content`,
            // and some turns legitimately have null content. Decoding it as a
            // non-optional `String` threw a Codable "data missing" error that
            // surfaced to the user as a raw decode failure. Resolve content,
            // then fall back to reasoning, before deciding it's truly empty.
            let text = (msg?.content?.isEmpty == false ? msg?.content : nil)
                ?? msg?.reasoning_content
            guard let text, !text.isEmpty else {
                throw LLMError.empty
            }
            return text
        } catch let error as LLMError {
            throw error
        } catch {
            // Include a snippet of the raw body so a shape mismatch (e.g. an
            // error JSON returned with HTTP 200) is diagnosable instead of an
            // opaque "data couldn't be read".
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw LLMError.decoding("\(error.localizedDescription) — body: \(snippet)")
        }
    }

    // MARK: - Wire types

    private struct Body: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let max_tokens: Int
        let temperature: Double
    }

    private struct Reply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                // Both OPTIONAL: reasoning models return `content: null` with
                // the answer in `reasoning_content`; either may be absent.
                let content: String?
                let reasoning_content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }
}
