import Foundation

public struct LLMMessage: Sendable, Codable {
    public enum Role: String, Sendable, Codable { case user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct LLMRequest: Sendable {
    public let model: String
    public let system: String
    public let messages: [LLMMessage]
    public let maxTokens: Int
    public let temperature: Double

    public init(model: String, system: String, messages: [LLMMessage],
                maxTokens: Int, temperature: Double) {
        self.model = model
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public enum LLMError: Error, Sendable {
    case transport(String)
    case http(status: Int, body: String)
    case decoding(String)
    case empty
}

/// The only thing the engine needs from an LLM: turn a request into text.
///
/// This is the "bring your own provider" seam. Wick collects the user's
/// provider + key + model in settings and hands the engine a concrete
/// implementation. Ship `AnthropicProvider` first; add OpenAI / an
/// OpenAI-compatible (Ollama, OpenRouter, Azure) provider behind the same
/// protocol later — no agent code changes.
public protocol LLMProvider: Sendable {
    func complete(_ request: LLMRequest) async throws -> String
}
