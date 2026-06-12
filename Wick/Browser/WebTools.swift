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
    // Incremental snapshot (TODO #42): `full` forces a fresh baseline,
    // `viewportOnly` walks only the visible region, `verbose` includes
    // decorative nodes. Returns NDJSON (base or `+`/`-`/`~` delta).
    var snapshot: @Sendable (_ full: Bool, _ viewportOnly: Bool, _ verbose: Bool) async -> String
    // click/type accept EITHER a stable `ref:N` (from snapshot) OR a CSS
    // selector (legacy / hand-driven) — a `.ref | .selector` target union.
    var click: @Sendable (_ ref: Int?, _ selector: String?) async -> String
    var type: @Sendable (_ ref: Int?, _ selector: String?, _ text: String, _ enter: Bool) async -> String
    var eval: @Sendable (_ js: String) async -> String
    var fetchJSON: @Sendable (_ url: String) async -> String
    // Multi-tab: the agent can run several pages at once and switch which one the
    // read/click/type/eval tools operate on. All tabs share one cookie store.
    var tabs: @Sendable () async -> String
    var newTab: @Sendable (_ url: String?) async -> String
    var switchTab: @Sendable (_ ref: String) async -> String
    var closeTab: @Sendable (_ ref: String) async -> String
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

/// Token-efficient INCREMENTAL snapshot. The first call (or after a real
/// navigation) returns the full compact tree as an NDJSON `base`; every
/// subsequent call returns ONLY what changed since the last snapshot as
/// `+`/`-`/`~` delta lines keyed on stable `ref:N` handles. This is the
/// mechanism that keeps multi-step agent runs cheap — we stop re-sending nodes
/// the model already saw (see `docs/research/webtool-snapshot-incremental-ax.md`).
struct WebSnapshotTool: AgentTool {
    let driver: WebToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "web.snapshot",
            description: "Get the page's interactive + structural elements (links, buttons, inputs, "
                + "headings) as a compact tree, each tagged with a stable `ref:N`. Pass that `ref` to "
                + "web.click / web.type. The FIRST snapshot returns the full tree (op:base, NDJSON); "
                + "later snapshots return ONLY what changed (op:delta with `+` added / `-` removed / "
                + "`~` mutated lines) so re-snapshotting after each action stays cheap. Refs are "
                + "stable across re-renders; the `[n]` index is volatile — always target by `ref`. "
                + "Use full:true to force a fresh full tree (e.g. if you've lost track). viewportOnly "
                + "limits the walk to the visible region on huge pages.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "full":         { "type": "boolean", "description": "Force a fresh full baseline instead of a delta (default false)." },
                "viewportOnly": { "type": "boolean", "description": "Only include elements in/near the visible viewport (default false)." },
                "verbose":      { "type": "boolean", "description": "Include decorative/structural nodes usually pruned (debug; default false)." }
              }
            }
            """)
    }
    private struct Args: Decodable { let full: Bool?; let viewportOnly: Bool?; let verbose: Bool? }
    func call(arguments: Data) async throws -> String {
        let a = (try? JSONDecoder().decode(Args.self, from: arguments))
        return ToolResultBounding.bound(
            await driver.snapshot(a?.full ?? false, a?.viewportOnly ?? false, a?.verbose ?? false))
    }
}

// MARK: - web.click

/// Click an element addressed by its stable `ref:N` (from web.snapshot) or by a
/// CSS selector (legacy). (Action tool — see the file-level safety note +
/// per-action-confirmation TODO.)
struct WebClickTool: AgentTool {
    let driver: WebToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "web.click",
            description: "Click an element. PREFER `ref` — the stable `ref:N` from web.snapshot "
                + "(resolves the exact element even after re-renders, with a RefStale guard if it's "
                + "gone). A CSS `selector` still works for hand-driven cases. Give exactly one. "
                + "Follow with web.snapshot/web.read to see the effect.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "ref":      { "type": "integer", "description": "Stable element ref (the N in ref:N) from web.snapshot. Preferred." },
                "selector": { "type": "string",  "description": "CSS selector of the element to click (legacy alternative to ref)." }
              }
            }
            """)
    }
    private struct Args: Decodable { let ref: Int?; let selector: String? }
    func call(arguments: Data) async throws -> String {
        let a = (try? JSONDecoder().decode(Args.self, from: arguments))
        let sel = a?.selector?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard a?.ref != nil || (sel?.isEmpty == false) else {
            return "ERROR: web.click needs a `ref` (from web.snapshot) or a `selector`."
        }
        return ToolResultBounding.bound(
            await driver.click(a?.ref, sel?.isEmpty == true ? nil : sel))
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
            description: "Type text into an input/textarea, optionally pressing Enter to submit. "
                + "PREFER `ref` — the stable `ref:N` from web.snapshot (with a RefStale guard). A CSS "
                + "`selector` still works for hand-driven cases. Give exactly one of ref/selector.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "ref":      { "type": "integer", "description": "Stable element ref (the N in ref:N) from web.snapshot. Preferred." },
                "selector": { "type": "string",  "description": "CSS selector of the input/textarea (legacy alternative to ref)." },
                "text":     { "type": "string",  "description": "Text to type." },
                "enter":    { "type": "boolean", "description": "Press Enter after typing (default false)." }
              },
              "required": ["text"]
            }
            """)
    }
    private struct Args: Decodable { let ref: Int?; let selector: String?; let text: String; let enter: Bool? }
    func call(arguments: Data) async throws -> String {
        let a = try JSONDecoder().decode(Args.self, from: arguments)
        let sel = a.selector?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard a.ref != nil || (sel?.isEmpty == false) else {
            return "ERROR: web.type needs a `ref` (from web.snapshot) or a `selector`."
        }
        return ToolResultBounding.bound(
            await driver.type(a.ref, sel?.isEmpty == true ? nil : sel, a.text, a.enter ?? false))
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

// MARK: - Tab-ref decoding

/// A tab reference the model may send as either a JSON string (`"2"`, a UUID) or
/// a JSON number (`2`). We coerce both to a string so the manager's permissive
/// `resolveTab` (index-or-id) handles them uniformly — saving a brittle
/// string-only schema that the model routinely violates by sending a raw number.
private enum TabRef {
    static func decode(_ data: Data) -> String? {
        struct AsString: Decodable { let tab: String? }
        struct AsInt: Decodable { let tab: Int? }
        if let s = (try? JSONDecoder().decode(AsString.self, from: data).tab) ?? nil,
           !s.isEmpty {
            return s
        }
        if let n = (try? JSONDecoder().decode(AsInt.self, from: data).tab) ?? nil {
            return String(n)
        }
        return nil
    }
}

// MARK: - web.tabs

/// List the agent browser's open tabs (index, title, URL, which is active). The
/// agent uses this to orient before switching/closing — multi-page workflows
/// (compare two stocks, keep a login parked) need to know what's open.
struct WebTabsTool: AgentTool {
    let driver: WebToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "web.tabs",
            description: "List the open browser tabs (index, title, URL, and which is active). "
                + "Use before web.switchTab / web.closeTab to see what's open.",
            parametersJSONSchema: """
            { "type": "object", "properties": {} }
            """)
    }
    func call(arguments: Data) async throws -> String {
        ToolResultBounding.bound(await driver.tabs())
    }
}

// MARK: - web.newTab

/// Open a NEW tab and make it active. The page shares cookies/logins with the
/// other tabs, so the agent can fan out work (e.g. one tab per ticker) without
/// losing context in the tab it came from.
struct WebNewTabTool: AgentTool {
    let driver: WebToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "web.newTab",
            description: "Open a new browser tab and make it active. Optionally navigate it to a URL "
                + "in one step. Subsequent web.read/click/type/eval operate on this new tab.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "url": { "type": "string", "description": "Optional URL to open in the new tab; omit for a blank tab." }
              }
            }
            """)
    }
    private struct Args: Decodable { let url: String? }
    func call(arguments: Data) async throws -> String {
        let url = (try? JSONDecoder().decode(Args.self, from: arguments).url) ?? nil
        let clean = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolResultBounding.bound(await driver.newTab(clean?.isEmpty == true ? nil : clean))
    }
}

// MARK: - web.switchTab

/// Make a given tab active so the other web.* tools operate on it. Accepts the
/// tab's index OR its id (both shown by web.tabs) — the agent shouldn't have to
/// track which form it remembered.
struct WebSwitchTabTool: AgentTool {
    let driver: WebToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "web.switchTab",
            description: "Make a tab active (by its index or id from web.tabs). After switching, "
                + "web.read/snapshot/click/type/eval/fetchJSON operate on that tab.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "tab": { "type": ["string", "number"], "description": "Tab index (1-based) or id from web.tabs." }
              },
              "required": ["tab"]
            }
            """)
    }
    func call(arguments: Data) async throws -> String {
        guard let ref = TabRef.decode(arguments) else {
            return "ERROR: missing or invalid `tab` (give an index or id from web.tabs)."
        }
        return ToolResultBounding.bound(await driver.switchTab(ref))
    }
}

// MARK: - web.closeTab

/// Close a tab the agent is done with. Never leaves zero tabs (closing the last
/// opens a fresh blank), so the agent can't strand the browser with no page.
struct WebCloseTabTool: AgentTool {
    let driver: WebToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "web.closeTab",
            description: "Close a tab (by its index or id from web.tabs). If it was active, a "
                + "neighbour becomes active; the browser always keeps at least one tab.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "tab": { "type": ["string", "number"], "description": "Tab index (1-based) or id from web.tabs." }
              },
              "required": ["tab"]
            }
            """)
    }
    func call(arguments: Data) async throws -> String {
        guard let ref = TabRef.decode(arguments) else {
            return "ERROR: missing or invalid `tab` (give an index or id from web.tabs)."
        }
        return ToolResultBounding.bound(await driver.closeTab(ref))
    }
}

// MARK: - Bundle

enum WebTools {
    /// The 11 `web.*` tools, built over a driver. `AgentRuntime` calls this inside
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
            WebTabsTool(driver: driver),
            WebNewTabTool(driver: driver),
            WebSwitchTabTool(driver: driver),
            WebCloseTabTool(driver: driver),
        ]
    }

    /// Names of the 11 tools — used by `AgentRuntime` to UNregister them when the
    /// flag is toggled off (the registry is keyed by `spec.name`).
    static let names = [
        "web.navigate", "web.read", "web.snapshot",
        "web.click", "web.type", "web.eval", "web.fetchJSON",
        "web.tabs", "web.newTab", "web.switchTab", "web.closeTab",
    ]
}
