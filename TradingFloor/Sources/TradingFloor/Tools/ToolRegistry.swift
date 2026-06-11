import Foundation

/// Where the chat agent finds its `AgentTool`s. The host registers concrete
/// tools at app start (MarketDataTool, Technicals, SocialSentiment, etc.);
/// the agent dispatches by name. Same registry pattern used by Anthropic's
/// tool-use API and MCP — kept agnostic so we can swap to native tool-use
/// later without changing how tools are written.
public actor ToolRegistry {
    private var tools: [String: any AgentTool] = [:]

    public init() {}

    public func register(_ tool: any AgentTool) {
        tools[tool.spec.name] = tool
    }

    public func registerAll(_ tools: [any AgentTool]) {
        for tool in tools { register(tool) }
    }

    /// Remove a tool by name. No-op if it isn't registered. Used by the host to
    /// retract opt-in tool families (e.g. Wicker's `web.*` browser tools) when
    /// the feature is toggled off, without rebuilding the whole registry.
    public func unregister(name: String) {
        tools[name] = nil
    }

    public func unregisterAll(names: [String]) {
        for name in names { tools[name] = nil }
    }

    public func all() -> [any AgentTool] {
        Array(tools.values).sorted { $0.spec.name < $1.spec.name }
    }

    public func tool(named name: String) -> (any AgentTool)? { tools[name] }

    /// Dispatch a tool by name. Throws `ToolDispatchError.unknownTool` if the
    /// name isn't registered — the chat agent surfaces this back to the model
    /// as an error result so it can recover (try a different tool, ask the
    /// user, give up gracefully).
    public func call(name: String, arguments: Data) async throws -> String {
        guard let tool = tools[name] else {
            throw ToolDispatchError.unknownTool(name: name, available: tools.keys.sorted())
        }
        return try await tool.call(arguments: arguments)
    }

    /// Markdown bullet list of every tool — name, description, JSON Schema —
    /// formatted for inlining into the agent's system prompt.
    public func descriptions() -> String {
        all().map { tool -> String in
            let spec = tool.spec
            return """
            - **\(spec.name)** — \(spec.description)
              Arguments (JSON Schema):
              \(indent(spec.parametersJSONSchema, by: "      "))
            """
        }.joined(separator: "\n\n")
    }

    private func indent(_ text: String, by prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }
}

public enum ToolDispatchError: Error, CustomStringConvertible {
    case unknownTool(name: String, available: [String])

    public var description: String {
        switch self {
        case .unknownTool(let name, let available):
            return "Unknown tool: \(name). Available: \(available.joined(separator: ", "))."
        }
    }
}
