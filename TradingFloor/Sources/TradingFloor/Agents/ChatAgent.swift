import Foundation

/// The free, interactive agent. Holds a conversation, lets the model call
/// registered tools mid-turn, and stops when the model produces a final
/// answer. Counterpart to `TradingFloor.analyze` — same `LLMProvider` + same
/// `AgentTool`s + same `Skill`s; the orchestration layer is what differs.
///
/// Tool dispatch is **prompted, not provider-native** — the model is asked to
/// emit fenced JSON blocks tagged `tool_use`, which we parse and run. This
/// keeps the agent provider-agnostic (Anthropic, OpenAI-compatible, Ollama
/// all just need to return text). Swap to a native tool-use API behind the
/// same `ChatAgent` interface when reliability warrants the extra surface.
public actor ChatAgent {
    public let llm: any LLMProvider
    public let tools: ToolRegistry
    public let skills: SkillRegistry
    public let config: TradingFloorConfig
    /// Hard cap on tool-call turns per user message. Belt-and-suspenders
    /// guard against a runaway loop where the model keeps re-issuing tools.
    public let maxToolTurns: Int

    public init(
        llm: any LLMProvider,
        tools: ToolRegistry,
        skills: SkillRegistry,
        config: TradingFloorConfig = .init(),
        maxToolTurns: Int = 6
    ) {
        self.llm = llm
        self.tools = tools
        self.skills = skills
        self.config = config
        self.maxToolTurns = maxToolTurns
    }

    /// One full user turn: append the user's message to `conversation`, then
    /// run the tool loop until the model produces a final (tool-free) reply.
    /// Returns the final assistant text; intermediate tool-call rounds are
    /// appended to `conversation` so the next user turn sees them. The
    /// `onEvent` callback fires for every step — useful for a streaming UI.
    public func respond(
        to userMessage: String,
        conversation: inout [LLMMessage],
        onEvent: (@Sendable (ChatEvent) -> Void)? = nil
    ) async throws -> String {
        let system = await buildSystemPrompt()
        conversation.append(LLMMessage(role: .user, content: userMessage))
        onEvent?(.userTurn(userMessage))

        for _ in 0..<maxToolTurns + 1 {     // +1 so the final no-tool reply still counts
            let request = LLMRequest(
                model: config.deepModel,
                system: system,
                messages: conversation,
                maxTokens: config.maxTokens,
                temperature: config.temperature
            )
            let raw = try await llm.complete(request)
            onEvent?(.assistantRaw(raw))
            conversation.append(LLMMessage(role: .assistant, content: raw))

            let calls = ToolCallParser.parse(raw)
            guard !calls.isEmpty else {
                let cleaned = ToolCallParser.stripFences(from: raw)
                onEvent?(.finalReply(cleaned))
                return cleaned
            }

            // Dispatch every tool call from this assistant turn, in order.
            var resultBlock = "Tool results:\n"
            for call in calls {
                onEvent?(.toolCall(name: call.tool, argumentsJSON: call.argumentsJSON))
                let output: String
                do {
                    let data = Data(call.argumentsJSON.utf8)
                    output = try await tools.call(name: call.tool, arguments: data)
                } catch {
                    output = "ERROR: \(error.localizedDescription)"
                }
                onEvent?(.toolResult(name: call.tool, output: output))
                resultBlock += "- \(call.tool):\n\(output)\n\n"
            }
            // Append as a user turn so the model sees fresh context for its
            // next attempt. Same shape as native tool_result blocks.
            conversation.append(LLMMessage(role: .user, content: resultBlock))
        }
        // Ran out of tool turns — return whatever the model said last.
        let last = conversation.last(where: { $0.role == .assistant })?.content ?? ""
        return ToolCallParser.stripFences(from: last)
    }

    // MARK: - System prompt assembly

    private func buildSystemPrompt() async -> String {
        let persona = await skills.skill(named: "desk-analyst")?.body
            ?? "You are the Wick desk analyst."
        let toolDocs = await tools.descriptions()
        let skillDocs = await skills.all()
            .filter { $0.name != "desk-analyst" }
            .map { "- `\($0.name)` — \($0.description)" }
            .joined(separator: "\n")

        return """
        \(persona)

        ## How to call tools

        To use a tool, emit a markdown code block fenced as `tool_use`
        containing a single JSON object with `tool` and `arguments`. Example:

        ```tool_use
        {"tool": "get_market_data", "arguments": {"symbol": "NVDA"}}
        ```

        You may emit multiple `tool_use` blocks in one reply. After the tools
        run, you will see their output in the next user message and can
        respond with a final answer (or call more tools).

        When you've answered the user's question, reply normally with **no**
        `tool_use` block.

        ## Available tools

        \(toolDocs)

        ## Available skills (consult by name when the question warrants depth)

        \(skillDocs)
        """
    }
}

/// Lightweight progress signal so a UI can render a "calling get_market_data…"
/// row, expanding into the result, etc.
public enum ChatEvent: Sendable {
    case userTurn(String)
    case assistantRaw(String)        // full raw model reply incl. fenced blocks
    case toolCall(name: String, argumentsJSON: String)
    case toolResult(name: String, output: String)
    case finalReply(String)
}

// MARK: - Tool-call parser

/// Extracts ```tool_use``` fenced JSON blocks from a model reply. The model
/// is instructed to emit them on their own line; the parser tolerates extra
/// whitespace and ignores any block whose JSON is malformed (returns it as
/// just text in the surrounding prose).
enum ToolCallParser {
    struct Call: Equatable {
        let tool: String
        let argumentsJSON: String   // raw JSON object as a string
    }

    static func parse(_ text: String) -> [Call] {
        let fence = "```tool_use"
        let close = "```"
        var calls: [Call] = []
        var cursor = text.startIndex
        while let openRange = text.range(of: fence, range: cursor..<text.endIndex) {
            let afterOpen = openRange.upperBound
            guard let closeRange = text.range(of: close, range: afterOpen..<text.endIndex) else { break }
            let payload = text[afterOpen..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let call = decodeCall(payload) { calls.append(call) }
            cursor = closeRange.upperBound
        }
        return calls
    }

    /// Strip every `tool_use` fence (and its payload) out of a reply, so the
    /// version we show to the user is clean. We only call this on the final
    /// no-tool reply, but it's a defensive cleanup for any straggler fences.
    static func stripFences(from text: String) -> String {
        let fence = "```tool_use"
        let close = "```"
        var out = ""
        var cursor = text.startIndex
        while let openRange = text.range(of: fence, range: cursor..<text.endIndex) {
            out += text[cursor..<openRange.lowerBound]
            guard let closeRange = text.range(of: close, range: openRange.upperBound..<text.endIndex) else {
                // Unbalanced fence — drop everything from the open onward.
                cursor = text.endIndex; break
            }
            cursor = closeRange.upperBound
        }
        out += text[cursor..<text.endIndex]
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeCall(_ payload: String) -> Call? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = obj["tool"] as? String
        else { return nil }
        let args = obj["arguments"] ?? [String: Any]()
        let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
        return Call(tool: tool, argumentsJSON: argsJSON)
    }
}
