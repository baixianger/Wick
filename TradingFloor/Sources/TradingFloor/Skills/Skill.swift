import Foundation

/// A skill is a *playbook* the agent can follow — instructions plus optional
/// hints about which tools it expects. Skills are authored as `.md` files
/// with YAML-ish frontmatter; the parser is intentionally minimal so users
/// can drop a new skill into their personal folder without learning YAML.
///
/// The frontmatter contract (only `name` + `description` are required):
///
/// ```yaml
/// ---
/// name: technical-analysis           # unique slug
/// description: One-line summary.     # shown in skill list / picker
/// triggers: [chart, rsi, momentum]   # optional — keywords that hint to the
///                                    # free agent that this skill is relevant
/// tools: [get_market_data]           # optional — tool names the skill calls;
///                                    # used for permission UI later
/// ---
/// ```
///
/// Everything after the closing `---` is the skill's body (markdown
/// instructions that go into a system prompt or get pasted into the chat).
public struct Skill: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let triggers: [String]
    public let tools: [String]
    public let body: String
    public let source: Source

    public enum Source: Sendable, Equatable {
        /// Shipped with the TradingFloor module (`Bundle.module`).
        case bundled
        /// User-supplied, loaded from a directory the user controls.
        case user(directoryName: String)
    }

    public init(
        name: String, description: String,
        triggers: [String] = [], tools: [String] = [],
        body: String, source: Source
    ) {
        self.name = name
        self.description = description
        self.triggers = triggers
        self.tools = tools
        self.body = body
        self.source = source
    }
}

/// Minimal Markdown-with-frontmatter parser. Supports:
///   - `key: value`            (single line)
///   - `key: [a, b, c]`        (inline list)
///   - quoted values: `key: "value"` or `key: 'value'`
/// Anything else in the frontmatter is ignored. The body is the rest of the
/// file (frontmatter is stripped). Returns nil if the file has no `---` head.
enum SkillParser {
    struct Parsed {
        let frontmatter: [String: Value]
        let body: String
    }
    enum Value: Equatable {
        case string(String)
        case list([String])
    }

    static func parse(_ text: String) -> Parsed? {
        // Frontmatter must start at the very first line.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---"
        else { return nil }

        // Find the closing fence.
        guard let closeIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }

        var fm: [String: Value] = [:]
        for line in lines[1..<closeIdx] {
            let l = String(line)
            guard let colon = l.firstIndex(of: ":") else { continue }
            let key = l[..<colon].trimmingCharacters(in: .whitespaces)
            let rawValue = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            fm[key] = parseValue(rawValue)
        }
        let body = lines[lines.index(after: closeIdx)...].joined(separator: "\n")
        return Parsed(frontmatter: fm, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseValue(_ raw: String) -> Value {
        // Inline list: [a, b, "c"]
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let inner = raw.dropFirst().dropLast()
            let items = inner.split(separator: ",").map {
                unquote(String($0).trimmingCharacters(in: .whitespaces))
            }
            return .list(items.filter { !$0.isEmpty })
        }
        return .string(unquote(raw))
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!, last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}

extension Skill {
    /// Build a `Skill` from raw markdown text. Returns nil if the file lacks
    /// usable frontmatter (`name` + `description` required).
    static func from(markdown: String, source: Source) -> Skill? {
        guard let parsed = SkillParser.parse(markdown),
              case .string(let name) = parsed.frontmatter["name"] ?? .string(""),
              !name.isEmpty,
              case .string(let desc) = parsed.frontmatter["description"] ?? .string(""),
              !desc.isEmpty
        else { return nil }

        let triggers: [String]
        switch parsed.frontmatter["triggers"] {
        case .list(let xs): triggers = xs
        case .string(let s) where !s.isEmpty: triggers = [s]
        default: triggers = []
        }
        let tools: [String]
        switch parsed.frontmatter["tools"] {
        case .list(let xs): tools = xs
        case .string(let s) where !s.isEmpty: tools = [s]
        default: tools = []
        }

        return Skill(
            name: name, description: desc,
            triggers: triggers, tools: tools,
            body: parsed.body, source: source
        )
    }
}
