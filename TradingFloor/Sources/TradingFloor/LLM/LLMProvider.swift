import Foundation

/// A single image attached to a message. The app side has already turned the
/// bytes into base64 (this layer never touches CoreGraphics/UIKit/AppKit so it
/// stays Linux-clean); we just relay `mimeType` + `base64` onto the wire in
/// whatever shape the target provider wants.
public struct LLMImage: Sendable, Codable, Hashable {
    public let mimeType: String   // e.g. "image/png", "image/jpeg"
    public let base64: String     // raw base64, NO data: prefix
    public init(mimeType: String, base64: String) { self.mimeType = mimeType; self.base64 = base64 }
}

public struct LLMMessage: Sendable, Codable {
    public enum Role: String, Sendable, Codable { case user, assistant }
    public let role: Role
    public let content: String
    /// Images attached to this turn. Defaults to empty so every existing
    /// call site and every plain-text turn behaves exactly as before — a
    /// message with no images is encoded as a bare string on the wire, byte
    /// for byte identical to the pre-multimodal path.
    public let images: [LLMImage]

    /// Existing text-only initializer. Kept verbatim (delegates with no
    /// images) so `LLMMessage(role:content:)` call sites compile unchanged.
    public init(role: Role, content: String) {
        self.init(role: role, content: content, images: [])
    }

    /// Multimodal initializer used by the attachment feature.
    public init(role: Role, content: String, images: [LLMImage]) {
        self.role = role
        self.content = content
        self.images = images
    }

    // Custom Decodable so JSON produced before `images` existed (which has no
    // `images` key) still decodes — `images` defaults to empty rather than
    // failing with a "key not found" error.
    private enum CodingKeys: String, CodingKey { case role, content, images }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try c.decode(Role.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.images = try c.decodeIfPresent([LLMImage].self, forKey: .images) ?? []
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
