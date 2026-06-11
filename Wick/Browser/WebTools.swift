import Foundation
import TradingFloor

/// Wicker's **browser-operation tools** — the app-side `AgentTool` conformers
/// that turn the embedded WebKit into the agent's hands on the web. Each tool
/// maps one capability of the general agent `WebPage` owned by
/// `BrowserSessionManager` (navigate / read / snapshot / click / type / eval /
/// fetchJSON), declares a JSON-schema spec the prompted tool-use loop reads,
/// and dispatches into the manager on the main actor.
///
/// **Why app-side.** The `TradingFloor` package is Foundation-only / Linux-clean
/// (so it builds on the server tier), so WebKit can't live there. These tools
/// are registered into the SAME `ToolRegistry` the package-side tools use —
/// exactly the seam `AgentRuntime` already uses for `MarketDataTool` — so from
/// `ChatAgent`'s perspective a `web.*` tool is indistinguishable from any other.
///
/// **Reaching the manager on the main actor.** `BrowserSessionManager` is
/// `@MainActor @available(macOS 26, *)`; an `AgentTool` is `Sendable` and its
/// `call` runs off any actor. We bridge with a `@Sendable` async closure
/// (`Driver`) captured at registration time that hops to `@MainActor` and calls
/// the manager. The tools hold that closure, never the manager directly, so the
/// `Sendable` conformance is clean and the macOS-26 availability is confined to
/// the registration site (`AgentRuntime`).
///
/// **Safety (MVP).** Read-ish tools (navigate / read / snapshot / fetchJSON, and
/// the read-only side of eval) run freely. The ACTION tools (`web.click`,
/// `web.type`, `web.eval`) are registered too — the MVP guardrail is the opt-in
/// `enableWickerBrowser` flag PLUS the live VISIBLE panel that auto-appears while
/// the agent drives the page, so the user always sees what it's doing and can
/// intervene. A per-action write-confirmation hook is the next hardening step.
// TODO: per-action confirmation — gate web.click / web.type / web.eval behind a
//       user-approval callback (e.g. a continuation the live panel resolves)
//       before the mutation runs, so destructive actions need explicit consent.

/// The main-actor bridge a `WebTool` calls to reach the browser. One closure per
/// capability; `AgentRuntime` builds these over the live `BrowserSessionManager`
/// at registration time (inside an `if #available(macOS 26)` block).
struct WebToolDriver: Sendable {
    var navigate: @Sendable (_ url: String) async -> String
    var readText: @Sendable (_ selector: String?) async -> String
    var snapshot: @Sendable () async -> String
    var click: @Sendable (_ selector: String) async -> String
    var type: @Sendable (_ selector: String, _ text: String, _ enter: Bool) async -> String
    var eval: @Sendable (_ js: String) async -> String
    var fetchJSON: @Sendable (_ url: String) async -> String
}

// MARK: - web.navigate

/// Navigate the agent's browser to a URL. The live panel reveals the page so the
/// user (and the agent, via follow-up reads) can see where it landed.
struct WebNavigateTool: AgentTool {
    let driver: WebToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "web.navigate",
            description: "Open a URL in the agent's embedded browser. Use this before reading, "
                + "snapshotting, clicking, or typing on a page. Returns the final URL + page title.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "url": { "type": "string", "description": "Absolute or bare URL, e.g. https://example.com or example.com" }
              },
              "required": ["url"]
            }
            """)
    }
    private struct Args: Decodable { let url: String }
    func call(arguments: Data) async throws -> String {
        let url = try JSONDecoder().decode(Args.self, from: arguments).url
        return ToolResultBounding.bound(await driver.navigate(url))
    }
}

// MARK: - web.read

/// Read the visible text of the current page (or of a CSS-selector subtree).
struct WebReadTool: AgentTool {
    let driver: WebToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "web.read",
            description: "Read visible text from the current page, or just the first element "
                + "matching a CSS selector. Returns the text (truncated if very long).",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "selector": { "type": "string", "description": "Optional CSS selector to scope the read; omit for the whole page body." }
              }
            }
            """)
    }
    private struct Args: Decodable { let selector: String? }
    func call(arguments: Data) async throws -> String {
        let sel = (try? JSONDecoder().decode(Args.self, from: arguments).selector) ?? nil
        let clean = sel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolResultBounding.bound(await driver.readText(clean?.isEmpty == true ? nil : clean))
    }
}

// MARK: - web.snapshot

/// Compact DOM outline (interactive + structural elements with role, name, and a
/// selector hint) so the agent can plan clicks/types.
struct WebSnapshotTool: AgentTool {
    let driver: WebToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "web.snapshot",
            description: "Get a compact outline of the current page's interactive + structural "
                + "elements (links, buttons, inputs, headings) with a selector hint for each. "
                + "Use this to find what to click or type into.",
            parametersJSONSchema: """
            { "type": "object", "properties": {} }
            """)
    }
    func call(arguments: Data) async throws -> String {
        ToolResultBounding.bound(await driver.snapshot())
    }
}

// MARK: - web.click

/// Click the first element matching a CSS selector. (Action tool — see the
/// file-level safety note + per-action-confirmation TODO.)
struct WebClickTool: AgentTool {
    let driver: WebToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "web.click",
            description: "Click the first element matching a CSS selector on the current page. "
                + "Find selectors with web.snapshot first. Follow with web.snapshot/web.read to see the effect.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "selector": { "type": "string", "description": "CSS selector of the element to click." }
              },
              "required": ["selector"]
            }
            """)
    }
    private struct Args: Decodable { let selector: String }
    func call(arguments: Data) async throws -> String {
        let sel = try JSONDecoder().decode(Args.self, from: arguments).selector
        return ToolResultBounding.bound(await driver.click(sel))
    }
}

// MARK: - web.type

/// Type text into the first element matching a CSS selector, optionally pressing
/// Enter. (Action tool — see the file-level safety note.)
struct WebTypeTool: AgentTool {
    let driver: WebToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "web.type",
            description: "Type text into the first input/textarea matching a CSS selector, "
                + "optionally pressing Enter to submit. Find the selector with web.snapshot first.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "selector": { "type": "string", "description": "CSS selector of the input/textarea." },
                "text":     { "type": "string", "description": "Text to type." },
                "enter":    { "type": "boolean", "description": "Press Enter after typing (default false)." }
              },
              "required": ["selector", "text"]
            }
            """)
    }
    private struct Args: Decodable { let selector: String; let text: String; let enter: Bool? }
    func call(arguments: Data) async throws -> String {
        let a = try JSONDecoder().decode(Args.self, from: arguments)
        return ToolResultBounding.bound(await driver.type(a.selector, a.text, a.enter ?? false))
    }
}

// MARK: - web.eval

/// Evaluate arbitrary JavaScript on the page. Powerful — both a read and a write
/// surface. (Action tool — see the file-level safety note.)
struct WebEvalTool: AgentTool {
    let driver: WebToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "web.eval",
            description: "Run JavaScript on the current page and return its result. The script may "
                + "`return` a value (string / number / object). Use for custom extraction or actions "
                + "no other tool covers. Prefer web.read / web.snapshot / web.click for the common cases.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "js": { "type": "string", "description": "JavaScript to run; may contain a `return` statement." }
              },
              "required": ["js"]
            }
            """)
    }
    private struct Args: Decodable { let js: String }
    func call(arguments: Data) async throws -> String {
        let js = try JSONDecoder().decode(Args.self, from: arguments).js
        return ToolResultBounding.bound(await driver.eval(js))
    }
}

// MARK: - web.fetchJSON

/// `fetch(url)` from inside the page (cookies ride along), returning status +
/// body. Lets the agent hit JSON APIs on a site it's already logged into.
struct WebFetchJSONTool: AgentTool {
    let driver: WebToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "web.fetchJSON",
            description: "Fetch a URL from inside the current page (so the page's cookies/session "
                + "are sent) and return the HTTP status + response body. Use for JSON APIs on a "
                + "site you've navigated to / logged into.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "url": { "type": "string", "description": "URL to fetch (absolute, or same-origin path like /api/x.json)." }
              },
              "required": ["url"]
            }
            """)
    }
    private struct Args: Decodable { let url: String }
    func call(arguments: Data) async throws -> String {
        let url = try JSONDecoder().decode(Args.self, from: arguments).url
        return ToolResultBounding.bound(await driver.fetchJSON(url))
    }
}

// MARK: - Bundle

enum WebTools {
    /// The 7 `web.*` tools, built over a driver. `AgentRuntime` calls this inside
    /// an `if #available(macOS 26)` block with a driver that forwards to the live
    /// `BrowserSessionManager`, then registers the result.
    static func all(driver: WebToolDriver) -> [any AgentTool] {
        [
            WebNavigateTool(driver: driver),
            WebReadTool(driver: driver),
            WebSnapshotTool(driver: driver),
            WebClickTool(driver: driver),
            WebTypeTool(driver: driver),
            WebEvalTool(driver: driver),
            WebFetchJSONTool(driver: driver),
        ]
    }

    /// Names of the 7 tools — used by `AgentRuntime` to UNregister them when the
    /// flag is toggled off (the registry is keyed by `spec.name`).
    static let names = [
        "web.navigate", "web.read", "web.snapshot",
        "web.click", "web.type", "web.eval", "web.fetchJSON",
    ]
}
