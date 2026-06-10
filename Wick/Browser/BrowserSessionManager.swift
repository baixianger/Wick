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

    /// Navigation/JS settle budget. Headless SPA renders can lag; bounded so a
    /// hung load still returns.
    @ObservationIgnored private let timeout: Duration

    /// In-flight status refresh, so concurrent callers coalesce.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(live: any XueqiuLiveScraping = XueqiuLiveScraper(),
         timeout: Duration = .seconds(20))
    {
        self.live = live
        self.timeout = timeout
        self.loginPage = live.makeLoginPage()
        // Start as needsLogin until the first probe says otherwise; the host
        // can call `refreshStatus()` after the user connects.
        self.status = .needsLogin
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
}
