import Foundation
import Observation
import TradingFloor
import os
#if canImport(WebKit)
import WebKit
#endif

/// App-scoped owner of the BYO-cookie 雪球 browser session (Mode 1 + Mode 2 of
/// `docs/research/webpage-byo-scraping-feasibility.md`). One instance lives for
/// the lifetime of the app (created in `WickApp`, injected via the environment
/// + into `AgentRuntime`), NOT in any View.
///
/// **In-WebKit JSON-API path (live-validated, probe `8a73738`).** The manager
/// owns the visible login `WebPage`; the injected `XueqiuLiveScraping` owns the
/// ONE persistent headless `WebPage` (same named store) loaded once at the light
/// xueqiu.com root, against which every status/discussion query is a same-origin
/// `callJavaScript(fetch('/api/…'))` — the cookie is inherited from the login.
/// We never DOM-scrape and never extract cookies: we operate inside our own
/// embedded WebKit, the equivalent of snowball-cli driving Chrome over CDP. The
/// persistent page is NEVER re-navigated per call (the -999 / overlapping-nav
/// fix lives in the live scraper).
///
/// **View-independent lifecycle (load-bearing):** the manager — not any View —
/// owns the visible `loginPage: WebPage` and (via the live scraper) the headless
/// data page. A view may *display* `loginPage` via `WebView(manager.loginPage)`,
/// but leaving that view never tears down either page or cancels an in-flight
/// query, because the references live here. This is exactly the ownership the
/// doc requires.
///
/// Conforms to the package's Foundation-only `XueqiuScraping` seam so the
/// off-by-default decorator (`BYODiscussionNewsDecorator`) can pull discussion
/// lines without importing WebKit. All WebKit work is delegated to the injected
/// `XueqiuLiveScraping` (live impl by default; a mock in tests).
/// One tab in the Wicker agent browser. Wraps a single driveable `WebPage`
/// (all tabs share the SAME persistent `agentStoreID` store, so cookies/logins
/// are common across tabs) plus the lightweight `title`/`url` the tab strip
/// chips render. `@Observable` so chip text/active tint update when the active
/// tab's navigation refreshes these after each load.
///
/// `page` is `@ObservationIgnored`: the reference never changes for a tab's
/// lifetime, and the macro can't synthesise an init-accessor for a
/// non-trivially-initialised stored property (same constraint as the manager's
/// `loginPage`).
@available(macOS 26.0, *)
@MainActor
@Observable
final class AgentTab: Identifiable {
    let id = UUID()
    @ObservationIgnored let page: WebPage   // on shared agentStoreID store
    var title: String = ""
    var url: URL?
    init(page: WebPage) { self.page = page }
}

@available(macOS 26.0, *)
@MainActor
@Observable
final class BrowserSessionManager: XueqiuScraping {

    /// Mode-2 session status, surfaced as `@Observable` state for a status row.
    private(set) var status: XueqiuSessionStatus = .unknown

    /// `XueqiuScraping` conformance — the decorator reads this (async) gate.
    var sessionStatus: XueqiuSessionStatus { status }

    /// The visible login page. Built once in `init` and held so the same
    /// `WebPage` instance backs `WebView(loginPage)` across redraws.
    /// `@ObservationIgnored` because the reference never changes and the
    /// `@Observable` macro can't synthesize an init-accessor for a
    /// non-trivially-initialised stored property (the prototype's verified
    /// constraint — a `lazy` here fails to compile).
    @ObservationIgnored private(set) var loginPage: WebPage

    @ObservationIgnored private let live: any XueqiuLiveScraping
    @ObservationIgnored private let log = Logger(subsystem: "me.impai.wick", category: "BrowserSession")

    // MARK: - X (Twitter) BYO session (Social tab, US/intl markets)
    //
    // The X sibling of the 雪球 path above. Same BYO shape — the user logs into X
    // ONCE in the visible `xLoginPage` and the cookie persists in the X named
    // store; the injected `XLiveScraping` owns the persistent headless page that
    // every per-stock search runs against. The CRITICAL difference is the
    // technique: X's private GraphQL needs an unforgeable `x-client-transaction-id`,
    // so we do NOT raw-fetch it. Instead each search NAVIGATES the headless page
    // ONCE to the human `/search?q=$SYMBOL&f=live` URL and does ONE DOM read of the
    // rendered tweets (the validated, ban-safe `XProbe.searchStock` technique).

    /// The visible X login page — built once and held so `WebView(xLoginPage)`
    /// backs the same `WebPage` across redraws. The user signs into X here once
    /// (password / 2FA / any automation challenge, all human-in-the-loop).
    /// `@ObservationIgnored` for the same reason as `loginPage`.
    @ObservationIgnored private(set) var xLoginPage: WebPage

    /// The injected X scraper (live WebKit impl by default; a mock in tests).
    @ObservationIgnored private let xLive: any XLiveScraping

    /// X session status, surfaced as `@Observable` state for the Social tab's X
    /// section state machine (reuses the 雪球 `XueqiuSessionStatus` enum since the
    /// states — needsLogin / valid / expired — are identical). Starts
    /// `needsLogin` until the first probe says otherwise.
    private(set) var xStatus: XueqiuSessionStatus = .needsLogin

    /// In-flight X status refresh, so concurrent callers coalesce.
    @ObservationIgnored private var xRefreshTask: Task<Void, Never>?

    /// Navigation/JS settle budget. Headless SPA renders can lag; bounded so a
    /// hung load still returns.
    @ObservationIgnored private let timeout: Duration

    /// In-flight status refresh, so concurrent callers coalesce.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    // MARK: - Wicker agent browser (general, driveable)

    /// **FIXED** persistent store identifier for the general "Wicker browser"
    /// profile — distinct from 雪球's jar so agent browsing can't read or
    /// pollute the 雪球 login (and vice-versa). Hardcoded once, by hand; a fresh
    /// UUID per launch would orphan the cookie jar (losing any logins the user
    /// established in the live panel) and break the panel-WebView ↔ tool cookie
    /// sharing. **MVP scope:** one shared profile for ALL sites the agent
    /// visits. Per-site isolation (a store per origin, so e.g. a broker login
    /// and a forum don't share cookies) is a hardening follow-up.
    static let agentStoreID = UUID(uuidString: "C4A7E218-6B93-4F0D-9E31-1A8D5C20F7B6")!

    /// The open agent-browser tabs. The general-purpose driveable `WebPage`s the
    /// `web.*` tools operate on and the live panel renders. Each is navigable to
    /// ANY url (unlike the 雪球 `loginPage`, pinned to xueqiu.com) and all share
    /// the SAME persistent `agentStoreID` store (common cookies/logins). Always
    /// holds AT LEAST one tab — closing the last replaces it with a fresh blank.
    /// `@Observable` (NOT ignored) so the tab strip + active `WebView` re-render
    /// when tabs are opened/closed/switched.
    private(set) var tabs: [AgentTab]

    /// The id of the active tab — the one the `web.*` tools drive and the panel
    /// displays. Observable so switching swaps the rendered `WebView`.
    private(set) var activeTabID: UUID

    /// The active tab, guarded against a stale `activeTabID` (falls back to the
    /// first tab, which always exists). Never force-unwraps.
    private var activeTab: AgentTab { tabs.first { $0.id == activeTabID } ?? tabs[0] }

    /// The active tab's `WebPage` — every driver method below operates on this.
    var activePage: WebPage { activeTab.page }

    /// Back-compat computed alias for the old single-page accessor, so existing
    /// references (e.g. the UI host) keep compiling. Always the ACTIVE page.
    var agentPage: WebPage { activePage }

    /// `true` while a `web.*` tool is mid-flight (a navigation, read, click,
    /// type, eval, or fetch). Drives the WickerView live panel: it slides in
    /// when this flips true and collapses when idle. Set true at the start of
    /// every tool's work and false (best-effort, via `defer`) when it returns.
    private(set) var isAgentBrowsing: Bool = false

    /// The agent page's current URL (best-effort — updated after each
    /// navigation). Surfaced so the live panel can show an address label.
    private(set) var agentCurrentURL: URL?

    /// Bounds every navigation / JS settle so a hung load still returns a
    /// verdict rather than stranding `isAgentBrowsing == true`.
    @ObservationIgnored private let agentTimeout: Duration = .seconds(25)

    init(live: any XueqiuLiveScraping = XueqiuLiveScraper(),
         xLive: any XLiveScraping = XLiveScraper(),
         timeout: Duration = .seconds(20))
    {
        self.live = live
        self.xLive = xLive
        self.timeout = timeout
        self.loginPage = live.makeLoginPage()
        self.xLoginPage = xLive.makeLoginPage()
        // Build exactly ONE tab, parked on about:blank (unchanged opt-in load
        // behaviour — no navigation fires until the agent/user asks).
        let firstTab = AgentTab(page: Self.makeAgentPage())
        self.tabs = [firstTab]
        self.activeTabID = firstTab.id
        // Start as needsLogin until the first probe says otherwise; the host
        // can call `refreshStatus()` / `xRefreshStatus()` after the user connects.
        self.status = .needsLogin
        self.xStatus = .needsLogin
    }

    /// Build the general agent `WebPage` on the named "Wicker browser" store.
    /// We do NOT navigate it here — it parks on `about:blank` until the agent's
    /// first `navigate(...)`, so opting into the feature doesn't fire a load.
    /// `static` so `init` can call it before `self` is formed.
    static func makeAgentPage() -> WebPage {
        var config = WebPage.Configuration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: agentStoreID)
        return WebPage(configuration: config)
    }

    // MARK: - Wicker agent browser: driver methods (tools call these)
    //
    // All `@MainActor` (inherited from the type), all best-effort: every method
    // returns a readable result string and NEVER throws / crashes, because a web
    // tool fault must surface to the model as a value it can recover from, not an
    // opaque host exception. Each method brackets its work with
    // `isAgentBrowsing` so the live panel reveals/collapses around the activity.
    // Returned text is bounded by the CALLER (the `web.*` tool) via
    // `ToolResultBounding`, so these can return rich strings.

    /// Run `body` with `isAgentBrowsing` held true for its duration. Re-entrant-
    /// safe via a simple depth counter so overlapping tool calls (the agent
    /// firing two in one turn) don't prematurely collapse the panel.
    @ObservationIgnored private var browsingDepth = 0
    private func withBrowsing<T>(_ body: () async -> T) async -> T {
        browsingDepth += 1
        isAgentBrowsing = true
        defer {
            browsingDepth -= 1
            if browsingDepth <= 0 { browsingDepth = 0; isAgentBrowsing = false }
        }
        return await body()
    }

    // MARK: - Wicker agent browser: tabs
    //
    // All `@MainActor` (inherited), all best-effort: each returns a readable
    // string and NEVER throws / crashes / force-unwraps. The tab set always holds
    // at least one tab; closing the last replaces it with a fresh blank. Every
    // tab shares the SAME persistent `agentStoreID` store, so a login in one tab
    // is visible in all others.

    /// Open a NEW tab on the shared store, make it active, optionally navigate it.
    /// Returns a one-line summary (`Opened tab N: <title> (<url>)`).
    func newTab(url: String?) async -> String {
        let tab = AgentTab(page: Self.makeAgentPage())
        tabs.append(tab)
        activeTabID = tab.id
        let index = tabs.count
        if let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Drive the existing nav path (now on the active page) so the same
            // settle/verdict + active-tab title/url refresh applies.
            _ = await navigate(to: url)
        } else {
            syncAgentURL(fallback: nil)
        }
        let title = tab.title.isEmpty ? "(new tab)" : tab.title
        let shown = tab.url?.absoluteString ?? "about:blank"
        return "Opened tab \(index): \(title) (\(shown))"
    }

    /// Make the tab referenced by `ref` (1-based index OR id string) active.
    /// Subsequent `web.read`/`web.click`/etc operate on it. Bad ref → clear error.
    func switchTab(ref: String) async -> String {
        guard let tab = resolveTab(ref) else { return "ERROR: no tab \(ref)" }
        activeTabID = tab.id
        syncAgentURL(fallback: tab.url)
        let title = tab.title.isEmpty ? "(new tab)" : tab.title
        return "Switched to tab \(indexOf(tab) ?? 0): \(title) (\(tab.url?.absoluteString ?? "about:blank"))"
    }

    /// Close the tab referenced by `ref` (1-based index OR id string). If it was
    /// the active tab, a neighbour becomes active; if it was the LAST tab, the set
    /// is replaced with one fresh blank tab (never zero). Bad ref → clear error.
    func closeTab(ref: String) async -> String {
        guard let tab = resolveTab(ref), let idx = indexOf(tab) else {
            return "ERROR: no tab \(ref)"
        }
        let wasActive = tab.id == activeTabID
        let closedLabel = "tab \(idx): \(tab.title.isEmpty ? "(new tab)" : tab.title)"
        tabs.removeAll { $0.id == tab.id }
        if tabs.isEmpty {
            // Never zero — replace with a fresh blank tab.
            let fresh = AgentTab(page: Self.makeAgentPage())
            tabs = [fresh]
            activeTabID = fresh.id
            syncAgentURL(fallback: nil)
            return "Closed \(closedLabel). Opened a fresh blank tab (it was the last one)."
        }
        if wasActive {
            // Pick a neighbour: the tab now at the closed slot, clamped.
            let newIndex = min(idx - 1, tabs.count - 1)   // idx is 1-based
            let neighbour = tabs[max(0, newIndex)]
            activeTabID = neighbour.id
            syncAgentURL(fallback: neighbour.url)
        }
        return "Closed \(closedLabel). \(tabs.count) tab(s) open."
    }

    /// Structured list of open tabs for the UI tab strip.
    func listTabs() -> [(index: Int, id: UUID, title: String, url: String, isActive: Bool)] {
        tabs.enumerated().map { (offset, tab) in
            (index: offset + 1,
             id: tab.id,
             title: tab.title,
             url: tab.url?.absoluteString ?? "about:blank",
             isActive: tab.id == activeTabID)
        }
    }

    /// Human-readable tab list for the `web.tabs` tool.
    func listTabsFormatted() -> String {
        let rows = listTabs().map { row -> String in
            let marker = row.isActive ? "* " : "  "
            let title = row.title.isEmpty ? "(new tab)" : row.title
            return "\(marker)\(row.index). \(title) — \(row.url)  [id \(row.id.uuidString)]"
        }
        return "Open tabs (\(rows.count)):\n" + rows.joined(separator: "\n")
    }

    /// Resolve a `ref` (1-based index OR full id string) to a tab, or nil.
    private func resolveTab(_ ref: String) -> AgentTab? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(trimmed), n >= 1, n <= tabs.count { return tabs[n - 1] }
        if let id = UUID(uuidString: trimmed) { return tabs.first { $0.id == id } }
        return nil
    }

    /// 1-based index of `tab` in the current set, or nil if absent.
    private func indexOf(_ tab: AgentTab) -> Int? {
        tabs.firstIndex { $0.id == tab.id }.map { $0 + 1 }
    }

    /// Refresh the ACTIVE tab's `title`/`url` from its page so chips update.
    /// Best-effort; called after navigation settles.
    private func refreshActiveTabMeta() async {
        let tab = activeTab
        tab.url = tab.page.url ?? agentCurrentURL
        let title = (try? await tab.page.callJavaScript("return document.title")) as? String
        if let title, !title.isEmpty { tab.title = title }
    }

    /// Navigate the agent page to `urlString` and report the outcome (final URL
    /// + page title once settled). Tolerates one superseded (-999) nav.
    func navigate(to urlString: String) async -> String {
        await withBrowsing {
            guard let url = Self.normalizedURL(urlString) else {
                return "ERROR: not a valid URL: \(urlString)"
            }
            log.info("[AgentBrowser] navigate → \(url.absoluteString, privacy: .public)")
            let events = activePage.load(URLRequest(url: url))
            let outcome = await awaitAgentNavigation(events)
            agentCurrentURL = url
            let title = (try? await activePage.callJavaScript("return document.title")) as? String
            await refreshActiveTabMeta()
            switch outcome {
            case .finished:
                return "Navigated to \(url.absoluteString)\nTitle: \(title ?? "(none)")"
            case .superseded:
                return "Navigated to \(url.absoluteString) (superseded nav tolerated)\nTitle: \(title ?? "(none)")"
            case .failed(let m):
                return "Navigation to \(url.absoluteString) reported: \(m). Page may still have partially loaded."
            case .timedOut:
                return "Navigation to \(url.absoluteString) timed out after \(agentTimeout); reading whatever rendered is still possible."
            }
        }
    }

    /// Read visible text from the page (or from `selector`'s first match).
    /// Returns the innerText, whitespace-collapsed. Best-effort.
    func readText(selector: String?) async -> String {
        await withBrowsing {
            do {
                let text = try await activePage.callJavaScript("""
                    try {
                        const sel = (s && s.length) ? s : null;
                        const root = sel ? document.querySelector(sel) : (document.body || document.documentElement);
                        if (!root) return sel ? ('NO_MATCH: ' + sel) : 'NO_BODY';
                        const t = (root.innerText || root.textContent || '').replace(/\\n{3,}/g, '\\n\\n').trim();
                        return t;
                    } catch (e) { return 'JSERR: ' + ((e && e.message) ? e.message : String(e)); }
                """, arguments: ["s": selector ?? ""]) as? String
                return text ?? "(no text)"
            } catch {
                return "ERROR: \(Self.agentErrorDetail(error))"
            }
        }
    }

    /// Token-efficient incremental AX/DOM snapshot (TODO #42, spec
    /// `docs/research/webtool-snapshot-incremental-ax.md` §4–§8). Routes the
    /// page-side `window.__wick` singleton: the FIRST call after a (real)
    /// navigation returns the full compact tree as an NDJSON `base`; subsequent
    /// calls return only the `+`/`-`/`~` delta lines keyed on stable `ref:N`
    /// handles. `full` forces a fresh baseline; `viewportOnly` walks only the
    /// visible region (+~1 screen) for big pages; `verbose` includes decorative
    /// nodes for debugging.
    ///
    /// `__wick` lives as a `window` global so it persists across `callJavaScript`
    /// calls and SPA navigations; a real navigation drops it → next call
    /// re-bootstraps and returns a fresh `base`, which is correct. The bootstrap
    /// is idempotent (`window.__wick ||= …`), so prepending it every time is safe.
    func snapshotOutline(full: Bool = false, viewportOnly: Bool = false, verbose: Bool = false) async -> String {
        await withBrowsing {
            do {
                let js = WickSnapshotJS.bootstrap + """

                    try {
                        return window.__wick.snapshot({ full: \(full), viewportOnly: \(viewportOnly), verbose: \(verbose) });
                    } catch (e) { return 'JSERR: ' + ((e && e.message) ? e.message : String(e)); }
                """
                let outline = try await activePage.callJavaScript(js) as? String
                return outline ?? "(empty snapshot)"
            } catch {
                return "ERROR: \(Self.agentErrorDetail(error))"
            }
        }
    }

    /// Click an element addressed EITHER by its stable `ref:N` (from
    /// `web.snapshot`) OR by a CSS `selector` (legacy / hand-driven). The ref
    /// path resolves through `__wick.click(ref)` → live element →
    /// scrollIntoView → real pointer/click events, with stale-ref safety: if the
    /// recorded element is gone or now presents a different `(role,name)`, it
    /// returns a `RefStale` string so the agent re-snapshots rather than acting
    /// on the wrong control. Best-effort; no navigation is awaited (SPA clicks
    /// route client-side) — follow with `web.snapshot`/`web.read`.
    func click(ref: Int? = nil, selector: String? = nil) async -> String {
        await withBrowsing {
            do {
                if let ref {
                    let js = WickSnapshotJS.bootstrap + """

                        try {
                            return window.__wick.click(\(ref));
                        } catch (e) { return 'JSERR: ' + ((e && e.message) ? e.message : String(e)); }
                    """
                    let res = try await activePage.callJavaScript(js) as? String
                    return res ?? "Click ref:\(ref): no result"
                }
                guard let selector, !selector.isEmpty else {
                    return "ERROR: web.click needs a `ref` (from web.snapshot) or a `selector`."
                }
                let res = try await activePage.callJavaScript("""
                    try {
                        const el = document.querySelector(sel);
                        if (!el) return 'NO_MATCH';
                        el.scrollIntoView({block:'center'});
                        el.click();
                        return 'CLICKED';
                    } catch (e) { return 'JSERR: ' + ((e && e.message) ? e.message : String(e)); }
                """, arguments: ["sel": selector]) as? String
                switch res {
                case "CLICKED":  return "Clicked \(selector)."
                case "NO_MATCH": return "No element matched \(selector)."
                default:         return "Click \(selector): \(res ?? "no result")"
                }
            } catch {
                return "ERROR: \(Self.agentErrorDetail(error))"
            }
        }
    }

    /// Type `text` into an element addressed EITHER by its stable `ref:N` (from
    /// `web.snapshot`) OR by a CSS `selector` (legacy), optionally pressing
    /// Enter. The ref path runs `__wick.type(ref,…)` (focus → React-safe native
    /// value-setter → input/change events → optional Enter) with the same
    /// stale-ref safety as `click`; the selector path keeps the original XProbe
    /// idiom.
    func type(ref: Int? = nil, selector: String? = nil, text: String, enter: Bool) async -> String {
        await withBrowsing {
            do {
                if let ref {
                    let js = WickSnapshotJS.bootstrap + """

                        try {
                            return window.__wick.type(\(ref), txt, doEnter);
                        } catch (e) { return 'JSERR: ' + ((e && e.message) ? e.message : String(e)); }
                    """
                    let res = try await activePage.callJavaScript(js, arguments: ["txt": text, "doEnter": enter]) as? String
                    return res ?? "Type ref:\(ref): no result"
                }
                guard let selector, !selector.isEmpty else {
                    return "ERROR: web.type needs a `ref` (from web.snapshot) or a `selector`."
                }
                let res = try await activePage.callJavaScript("""
                    try {
                        const el = document.querySelector(sel);
                        if (!el) return 'NO_MATCH';
                        el.focus();
                        const proto = Object.getPrototypeOf(el);
                        const desc = Object.getOwnPropertyDescriptor(proto, 'value');
                        if (desc && desc.set) { desc.set.call(el, txt); } else { el.value = txt; }
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                        if (doEnter) {
                            const k = { key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true, cancelable:true };
                            el.dispatchEvent(new KeyboardEvent('keydown', k));
                            el.dispatchEvent(new KeyboardEvent('keypress', k));
                            el.dispatchEvent(new KeyboardEvent('keyup', k));
                        }
                        return 'TYPED';
                    } catch (e) { return 'JSERR: ' + ((e && e.message) ? e.message : String(e)); }
                """, arguments: ["sel": selector, "txt": text, "doEnter": enter]) as? String
                switch res {
                case "TYPED":    return "Typed into \(selector)\(enter ? " and pressed Enter" : "")."
                case "NO_MATCH": return "No element matched \(selector)."
                default:         return "Type \(selector): \(res ?? "no result")"
                }
            } catch {
                return "ERROR: \(Self.agentErrorDetail(error))"
            }
        }
    }

    /// Evaluate arbitrary JavaScript on the page and return its result coerced
    /// to a readable string. The script may `return` a value (string / number /
    /// bool / JSON-serialisable object). Best-effort.
    func eval(js: String) async -> String {
        await withBrowsing {
            do {
                // Wrap so callers can pass either an expression or statements;
                // serialise non-string results to JSON for readability.
                let wrapped = """
                    try {
                        const __r = (function(){ \(js) })();
                        if (__r === undefined || __r === null) return String(__r);
                        if (typeof __r === 'string') return __r;
                        try { return JSON.stringify(__r); } catch (e) { return String(__r); }
                    } catch (e) { return 'JSERR: ' + ((e && e.message) ? e.message : String(e)); }
                """
                let res = try await activePage.callJavaScript(wrapped)
                if let s = res as? String { return s }
                if let n = res { return String(describing: n) }
                return "(no result)"
            } catch {
                return "ERROR: \(Self.agentErrorDetail(error))"
            }
        }
    }

    /// Same-origin (or CORS-permitting) `fetch(url)` driven from the agent
    /// page, returning the response status + body. Because it runs INSIDE the
    /// page, the page's cookies ride along (`credentials:'include'`) — the
    /// same in-WebKit API path the 雪球 scraper uses. Best-effort.
    func fetchJSON(url: String) async -> String {
        await withBrowsing {
            do {
                let obj = try await activePage.callJavaScript("""
                    try {
                        const r = await fetch(u, { method: 'GET', credentials: 'include' });
                        const text = await r.text();
                        return { status: r.status, len: text.length, body: text };
                    } catch (e) { return { error: ((e && e.message) ? e.message : String(e)) }; }
                """, arguments: ["u": url]) as? [String: Any]
                if let err = obj?["error"] as? String { return "FETCH ERROR: \(err)" }
                let status = (obj?["status"] as? Int) ?? -1
                let len = (obj?["len"] as? Int) ?? 0
                let body = (obj?["body"] as? String) ?? ""
                return "HTTP \(status) (\(len) chars)\n\(body)"
            } catch {
                return "ERROR: \(Self.agentErrorDetail(error))"
            }
        }
    }

    // MARK: - Wicker agent browser: USER-driven navigation (address bar)
    //
    // The live panel's address bar + back/forward/reload buttons call these. They
    // drive the SAME `agentPage` the `web.*` tools read/operate — that is the whole
    // point: a page the user opens by hand becomes the page the agent then sees via
    // `web.read`/`web.snapshot`/etc. We deliberately do NOT spin up a second page.
    //
    // Unlike the tool drivers above these are NOT bracketed by `withBrowsing`: a
    // user typing a URL isn't the *agent* browsing, so we don't want the panel's
    // "Wicker is browsing…" affordance to flash. We still keep `agentCurrentURL`
    // current so the address field reflects the live location.

    /// Load `agentPage` to `url` on the user's behalf (address-bar submit). Mirrors
    /// the `navigate(to:)` idiom — `load(URLRequest:)`, drive the returned event
    /// sequence to a verdict (tolerating a superseded -999 nav), then refresh
    /// `agentCurrentURL` from the page so the bar tracks redirects. Best-effort and
    /// non-throwing, like every other driver here.
    func userNavigate(_ url: URL) async {
        log.info("[AgentBrowser] userNavigate → \(url.absoluteString, privacy: .public)")
        let events = activePage.load(URLRequest(url: url))
        _ = await awaitAgentNavigation(events)
        syncAgentURL(fallback: url)
        await refreshActiveTabMeta()
    }

    /// Reload the current page (address-bar reload button). Uses `WebPage`'s native
    /// `reload()`, which returns the same (non-optional) `NavigationEvent` sequence
    /// `load` does — settle it through the shared helper, then re-sync the URL.
    func reload() async {
        log.info("[AgentBrowser] reload")
        let events = activePage.reload()
        _ = await awaitAgentNavigation(events)
        syncAgentURL(fallback: agentCurrentURL)
        await refreshActiveTabMeta()
    }

    /// Step back in `agentPage`'s history (address-bar back button). The macOS 26
    /// `WebPage` surface exposes no `goBack()`, so we drive it the way the rest of
    /// this file drives the page — in-page JS (`history.back()`). The hop routes
    /// client-side (no `load` event sequence to await), so we let the page settle
    /// briefly, then re-sync the URL. Best-effort.
    func goBack() async {
        log.info("[AgentBrowser] goBack")
        _ = try? await activePage.callJavaScript("history.back()")
        await settleAndSyncURL()
    }

    /// Step forward in `agentPage`'s history (address-bar forward button). Same
    /// rationale as `goBack()`: no native `goForward()`, so drive `history.forward()`
    /// in-page, settle, and re-sync the URL. Best-effort.
    func goForward() async {
        log.info("[AgentBrowser] goForward")
        _ = try? await activePage.callJavaScript("history.forward()")
        await settleAndSyncURL()
    }

    /// Give a JS-driven history hop a brief moment to commit, then re-sync the
    /// address bar from the page's authoritative URL. The wait is bounded and
    /// best-effort — a missed update just leaves the prior URL showing.
    private func settleAndSyncURL() async {
        try? await Task.sleep(for: .milliseconds(150))
        syncAgentURL(fallback: agentCurrentURL)
        await refreshActiveTabMeta()
    }

    /// Pull the page's authoritative current URL into `agentCurrentURL` so the
    /// address bar mirrors redirects / history hops, falling back to the supplied
    /// value when the page hasn't published one yet (e.g. about:blank).
    private func syncAgentURL(fallback: URL?) {
        if let live = activePage.url {
            agentCurrentURL = live
        } else if let fallback {
            agentCurrentURL = fallback
        }
    }

    // MARK: - Agent-browser helpers

    /// Coerce a user/agent-supplied URL string into a `URL`, defaulting the
    /// scheme to https when omitted (so `example.com` works). Returns nil for
    /// anything that still can't be parsed.
    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let u = URL(string: trimmed), u.scheme != nil { return u }
        return URL(string: "https://\(trimmed)")
    }

    /// Compact navigation outcome for the agent driver (mirrors the probe's
    /// idiom but folds -999/cancelled into an explicit `.superseded`).
    private enum AgentNav: Equatable {
        case finished, superseded, failed(String), timedOut
    }

    /// Drive `WebPage.load(_:)`'s event sequence to a verdict, racing
    /// `agentTimeout`. Verbatim shape of the XProbe idiom.
    private func awaitAgentNavigation<S: AsyncSequence>(_ events: S) async -> AgentNav
        where S.Element == WebPage.NavigationEvent
    {
        let iterate = Task { @MainActor () -> AgentNav in
            do {
                for try await event in events {
                    switch event {
                    case .finished: return .finished
                    case .startedProvisionalNavigation, .receivedServerRedirect, .committed: continue
                    @unknown default: continue
                    }
                }
                return Task.isCancelled ? .timedOut : .failed("stream ended without finishing")
            } catch is CancellationError {
                return .timedOut
            } catch {
                let m = error.localizedDescription
                if m.contains("-999") || m.localizedCaseInsensitiveContains("cancel") { return .superseded }
                return .failed(m)
            }
        }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: agentTimeout)
            iterate.cancel()
        }
        let outcome = await iterate.value
        watchdog.cancel()
        return outcome
    }

    /// Pull the underlying JS exception out of a thrown WebKit error (the
    /// XProbe `errorDetail` idiom) so faults are actionable, not opaque.
    private static func agentErrorDetail(_ error: Error) -> String {
        let ns = error as NSError
        if let msg = ns.userInfo["WKJavaScriptExceptionMessage"] as? String, !msg.isEmpty {
            let line = ns.userInfo["WKJavaScriptExceptionLineNumber"] as? Int
            return "JS: \(msg)" + (line.map { " (line \($0))" } ?? "")
        }
        return error.localizedDescription
    }

    // MARK: - Login / logout

    /// Expose the visible page for the user to sign in (password / SMS / captcha
    /// — all human-in-the-loop). The View renders `WebView(manager.loginPage)`.
    /// Reloads the login origin so a stale page doesn't strand the user.
    func login() {
        log.info("[BrowserSession] login: presenting visible page")
        loginPage.load(URLRequest(url: XueqiuLiveScraper.loginURL))
    }

    /// Clear the named store's cookies so the session is forgotten, then flip to
    /// `needsLogin`. Best-effort — failure just leaves the status as-is.
    func logout() async {
        log.info("[BrowserSession] logout: clearing session cookies")
        #if canImport(WebKit)
        let store = WKWebsiteDataStore(forIdentifier: XueqiuLiveScraper.storeID)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
        #endif
        status = .needsLogin
    }

    // MARK: - Mode-2 status state machine

    /// Cheap logged-in probe → updates `status`. Coalesces concurrent calls.
    /// Maps the live probe's verdict (`valid` / `expired` / `unknown`) onto the
    /// state machine; `unknown` from the probe is preserved as `unknown` (the
    /// host can retry) rather than guessing.
    func refreshStatus() async {
        if let task = refreshTask { return await task.value }
        let task = Task { @MainActor in
            let probed = await live.probeStatus(timeout: timeout)
            self.status = probed
            self.log.info("[BrowserSession] refreshStatus → \(probed.rawValue, privacy: .public)")
            self.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    // MARK: - XueqiuScraping

    /// Pre-formatted 雪球 discussion news lines, best-effort. Returns `[]` (never
    /// throws) when the session isn't scrapable, the symbol isn't CN/HK, or the
    /// in-WebKit `fetch` is empty / times out — so the decorator degrades to a
    /// pass-through. The lines arrive already formatted (`[雪球·作者] … (赞n 评n)`)
    /// from the live scraper's per-call `fetch('/statuses/search.json')`.
    func discussion(for symbol: String) async -> [String] {
        guard status.canScrape else { return [] }
        guard CNSymbol.isCN(symbol) else { return [] }
        // An empty result (logged-out / no posts) leaves status untouched here —
        // best-effort means just return []; a dedicated reactive-capture pass can
        // be layered on later.
        return await live.extractDiscussion(symbol: symbol, timeout: timeout)
    }

    // MARK: - Structured posts (Social tab)

    /// STRUCTURED 雪球 discussion posts for the per-stock **Social** tab, parsed
    /// into `XueqiuPost` (author, text, 赞/评 counts, time, url) rather than the
    /// decorator's flat news lines. Same best-effort contract as
    /// `discussion(for:)`: returns `[]` (never throws) when the session isn't
    /// scrapable, the symbol isn't CN/HK, or the in-WebKit `fetch` is empty /
    /// times out — so the Social UI degrades to its empty state.
    ///
    /// Distinct from `discussion(for:)` (which the sentiment decorator owns and
    /// must keep its `[String]` shape): this is the UI-facing structured seam.
    func posts(for symbol: String) async -> [XueqiuPost] {
        guard status.canScrape else { return [] }
        guard CNSymbol.isCN(symbol) else { return [] }
        return await live.extractPosts(symbol: symbol, timeout: timeout)
    }

    // MARK: - X (Twitter) login / status / posts (Social tab)

    /// Expose the visible X page for the user to sign in (password / 2FA / any
    /// automation challenge — all human-in-the-loop). The View renders
    /// `WebView(manager.xLoginPage)`. Reloads `/home` so a stale page doesn't
    /// strand the user.
    func xLogin() {
        log.info("[BrowserSession] xLogin: presenting visible X page")
        xLoginPage.load(URLRequest(url: XLiveScraper.homeURL))
    }

    /// Clear the X named store's cookies so the X session is forgotten, then flip
    /// `xStatus` to `needsLogin`. Independent of the 雪球 jar — clears only X.
    /// Best-effort — failure just leaves the status as-is.
    func xLogout() async {
        log.info("[BrowserSession] xLogout: clearing X session cookies")
        #if canImport(WebKit)
        let store = WKWebsiteDataStore(forIdentifier: XLiveScraper.storeID)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
        #endif
        xStatus = .needsLogin
    }

    /// Cheap logged-in X probe → updates `xStatus`. Coalesces concurrent calls.
    /// Mirrors `refreshStatus()` for the 雪球 path.
    func xRefreshStatus() async {
        if let task = xRefreshTask { return await task.value }
        let task = Task { @MainActor in
            let probed = await xLive.probeStatus(timeout: timeout)
            self.xStatus = probed
            self.log.info("[BrowserSession] xRefreshStatus → \(probed.rawValue, privacy: .public)")
            self.xRefreshTask = nil
        }
        xRefreshTask = task
        await task.value
    }

    /// Recent X discussion posts for the per-stock **Social** tab (US / intl
    /// markets). Builds the `$SYMBOL` cashtag and runs the validated, ban-safe
    /// single-shot navigation-driven search + DOM read via the injected scraper.
    /// Same best-effort contract as the 雪球 `posts(for:)`: returns `[]` (never
    /// throws) when the X session isn't scrapable or the single search came back
    /// empty / timed out — so the Social UI degrades to its empty state. The
    /// symbol is reduced to its bare ticker before the `$` (US tickers are bare;
    /// any exchange suffix like `.US` is dropped) so the cashtag matches X usage.
    func xPosts(for symbol: String) async -> [XPost] {
        guard xStatus.canScrape else { return [] }
        let cashtag = Self.cashtag(for: symbol)
        guard !cashtag.isEmpty else { return [] }
        return await xLive.searchPosts(cashtag: cashtag, timeout: timeout)
    }

    /// Build the X cashtag (`$TSLA`) from a stored symbol. Strips any exchange
    /// suffix (`AAPL.US` → `AAPL`) and uppercases, since X cashtags are the bare
    /// ticker. Returns `""` for an empty/garbage symbol so `xPosts` can bail.
    static func cashtag(for symbol: String) -> String {
        let bare = symbol.split(separator: ".").first.map(String.init) ?? symbol
        let cleaned = bare.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleaned.isEmpty else { return "" }
        return "$\(cleaned)"
    }
}
