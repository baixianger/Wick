import Foundation
import WebKit
import TradingFloor
import os

/// The actual WebKit work behind the `BrowserSessionManager`, split out so the
/// manager itself stays testable: the manager talks to this small seam, and
/// unit tests inject a mock instead of driving real WebKit.
///
/// **In-WebKit JSON-API design (live-validated, probe `8a73738`).** We do NOT
/// scrape the SPA's DOM and we do NOT extract cookies to a `URLSession`. Instead
/// we operate INSIDE our own embedded WebKit: a headless `WebPage` on the named
/// store is loaded ONCE at the LIGHT root `https://xueqiu.com/`, then every query
/// is a same-origin `await fetch('/api/…')` driven via `callJavaScript`. The
/// inherited login cookie is auto-attached (`credentials:'include'`), so 雪球's
/// JSON endpoints answer exactly as they do for the logged-in browser. This is
/// the equivalent of how snowball-cli drives Chrome over CDP — `callJavaScript`
/// is our `Runtime.evaluate`.
///
/// **The -999 fix (load-bearing).** The probe was unstable (`NSURLErrorDomain
/// -999`, cancelled) because it built a FRESH `WebPage` and NAVIGATED to the
/// heavy stock SPA on every call — overlapping navigations cancel each other.
/// Here there is exactly ONE long-lived headless page, navigated ONCE to the
/// light root; every query is just a `fetch` on that already-loaded page. No
/// per-call navigation ⇒ no -999. We reload only if the page is missing.
///
/// REUSES the compiler-verified `WebPage` API patterns from the probe:
///   • `WKWebsiteDataStore(forIdentifier:)` with a FIXED persistent UUID,
///   • `WebPage.Configuration().websiteDataStore`,
///   • `page.load(_:)` RETURNS a `some AsyncSequence<NavigationEvent, Error>`
///     iterated with `for try await` (no `currentNavigationEvent`, no
///     `NavigationID`); failures are THROWN as `WebPage.NavigationError`, so we
///     race a timeout watchdog,
///   • `callJavaScript(_:arguments:in:contentWorld:)` → optional `Any`,
///   • the probe's self-reporting JS + `errorDetail()` (pull the JS exception).
@available(macOS 26.0, *)
@MainActor
protocol XueqiuLiveScraping: Sendable {
    /// Build the visible login page bound to the named persistent store and
    /// kick off a load of the 雪球 origin. Returned page backs `WebView(page)`.
    func makeLoginPage() -> WebPage
    /// Cheap logged-in probe via the persistent headless page:
    /// `fetch('/statuses/hots.json')` → valid JSON without an `error_code` ⇒
    /// `.valid`; an `error_code` / login-wall HTML ⇒ `.expired`; `.unknown` if
    /// the page couldn't be readied or the probe couldn't settle.
    func probeStatus(timeout: Duration) async -> XueqiuSessionStatus
    /// Pre-formatted discussion news lines for a canonical CN/HK symbol, fetched
    /// on the same persistent page. Best-effort: `[]` on no-session / empty /
    /// timeout / error; never throws.
    func extractDiscussion(symbol: String, timeout: Duration) async -> [String]
    /// STRUCTURED discussion posts for a canonical CN/HK symbol — the same
    /// same-origin `/statuses/search.json` fetch as `extractDiscussion`, but
    /// returning the parsed `XueqiuPost` values (author, text, 赞/评, time, url)
    /// for the Social tab's card UI instead of the decorator's flat news lines.
    /// Best-effort: `[]` on no-session / empty / timeout / error; never throws.
    func extractPosts(symbol: String, timeout: Duration) async -> [XueqiuPost]
}

/// Live, WebKit-backed implementation. Owns the ONE persistent headless
/// `WebPage` (on the named store) that every query runs against — loaded lazily
/// at the light xueqiu.com root and reused; never re-navigated per call.
@available(macOS 26.0, *)
@MainActor
final class XueqiuLiveScraper: XueqiuLiveScraping {

    /// FIXED persistent store identifier — same one the prototype validated.
    /// Recreating the store with this UUID on relaunch is what restores the
    /// logged-in session; it MUST be hardcoded (a fresh UUID per launch would
    /// orphan the cookie jar and break both persistence and cross-store cookie
    /// visibility). Distinct from the probe's UUID so the dev probe and the
    /// production session don't share a jar.
    static let storeID = UUID(uuidString: "B2F4C7D9-1A6E-4C3B-8F50-9D7E2A1C5B40")!

    /// LIGHT root the persistent headless page is loaded at — NOT the heavy
    /// per-stock SPA (`/S/SH600519`). All per-stock data comes from same-origin
    /// `fetch`es against this one already-loaded origin.
    static let loginURL = URL(string: "https://xueqiu.com")!

    /// How many recent posts to pull per stock. The decorator caps the appended
    /// lines again; this just bounds the fetch.
    static let postCount = 20

    private let log = Logger(subsystem: "me.impai.wick", category: "XueqiuLiveScraper")

    // MARK: - Persistent headless page (the -999 fix)

    /// The ONE long-lived headless page every query runs against. Built + loaded
    /// at the light root on first use, then reused — NEVER re-navigated per call.
    /// `nil` until first readied (or after a tear-down), so `readyPage` can
    /// rebuild it lazily.
    private var dataPage: WebPage?

    /// Coalesces concurrent first-use loads so two queries racing in don't each
    /// kick a navigation (which would re-introduce the overlapping-nav -999).
    private var readyTask: Task<WebPage?, Never>?

    private func makeStore() -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: Self.storeID)
    }

    func makeLoginPage() -> WebPage {
        var config = WebPage.Configuration()
        config.websiteDataStore = makeStore()
        let page = WebPage(configuration: config)
        log.info("[Xueqiu] login page bound to store \(Self.storeID.uuidString, privacy: .public)")
        page.load(URLRequest(url: Self.loginURL))
        return page
    }

    /// Return the persistent headless page, loading it ONCE at the light root if
    /// it isn't ready yet. Tolerates a -999/cancelled (superseded) navigation by
    /// retrying the load once. Concurrent callers coalesce onto one `readyTask`.
    /// Returns `nil` only if the page genuinely couldn't be readied.
    private func readyPage(timeout: Duration) async -> WebPage? {
        if let page = dataPage { return page }   // already loaded — reuse, no nav
        if let task = readyTask { return await task.value }

        let task = Task { @MainActor () -> WebPage? in
            defer { self.readyTask = nil }
            var config = WebPage.Configuration()
            config.websiteDataStore = self.makeStore()
            let page = WebPage(configuration: config)

            // Load the LIGHT root once. A -999 (cancelled / superseded) is
            // tolerated and retried a single time — past that we give up.
            for attempt in 1...2 {
                let events = page.load(URLRequest(url: Self.loginURL))
                let outcome = await Self.awaitFinished(events, timeout: timeout)
                if outcome { self.dataPage = page; return page }
                self.log.info("[Xueqiu] root load attempt \(attempt) did not finish; \(attempt < 2 ? "retrying" : "giving up")")
            }
            return nil
        }
        readyTask = task
        return await task.value
    }

    // MARK: - Symbol mapping

    /// Map a canonical CN/HK symbol (`600519.SS` / `0700.HK`) to the 雪球 path
    /// form (`SH600519` / `00700`). Delegates to the package's centralised
    /// `CNSymbol.xueqiuSymbol` (Foundation-only, unit-tested there).
    static func xueqiuSymbol(forCanonical canonical: String) -> String? {
        CNSymbol.xueqiuSymbol(canonical)
    }

    // MARK: - Status probe (per-call fetch on the persistent page)

    func probeStatus(timeout: Duration) async -> XueqiuSessionStatus {
        guard let page = await readyPage(timeout: timeout) else { return .unknown }
        do {
            // Self-reporting JS (probe pattern): a well-formed JSON body without
            // an `error_code` ⇒ the page inherited a working session (.valid);
            // a non-zero `error_code` / non-JSON ⇒ logged out / walled (.expired).
            let verdict = try await page.callJavaScript("""
                try {
                    const r = await fetch('/statuses/hots.json?a=1&count=1&page=1&scope=day&type=status&meigu=0', {
                        credentials: 'include',
                        headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
                    });
                    const text = await r.text();
                    let json = null; try { json = JSON.parse(text); } catch (e) {}
                    if (!json)       return 'expired';
                    if (json.error_code && json.error_code != 0) return 'expired';
                    return 'valid';
                } catch (e) {
                    return 'JSERR: ' + ((e && e.message) ? e.message : String(e));
                }
            """) as? String
            switch verdict {
            case .some("valid"):   return .valid
            case .some("expired"): return .expired
            default:
                log.error("[Xueqiu] status probe → \(verdict ?? "nil", privacy: .public)")
                return .unknown
            }
        } catch {
            log.error("[Xueqiu] status probe failed: \(Self.errorDetail(error), privacy: .public)")
            return .unknown
        }
    }

    // MARK: - Discussion extract (per-call fetch on the persistent page)

    func extractDiscussion(symbol: String, timeout: Duration) async -> [String] {
        // Reuse the structured path then flatten to the decorator's news lines —
        // one fetch shape, one parse, two projections (lines here, cards in the
        // Social tab). Keeps the formatting authoritative in `XueqiuPost`.
        await extractPosts(symbol: symbol, timeout: timeout).map { $0.newsLine() }
    }

    func extractPosts(symbol: String, timeout: Duration) async -> [XueqiuPost] {
        guard let xq = Self.xueqiuSymbol(forCanonical: symbol) else { return [] }
        guard let page = await readyPage(timeout: timeout) else { return [] }

        do {
            // SAME-ORIGIN per-stock posts: `/statuses/search.json?q=<symbol>` —
            // the simplest single same-origin call returning recent posts for a
            // symbol (snowball-cli `searchPosts`, sorted newest-first). Returns
            // the raw JSON body as a string; parsing happens in the package's
            // pure `XueqiuPostParser` so it's unit-testable.
            let body = try await page.callJavaScript("""
                try {
                    const url = '/statuses/search.json?q=' + encodeURIComponent(q)
                        + '&count=' + count + '&page=1&sort=time&source=all';
                    const r = await fetch(url, {
                        credentials: 'include',
                        headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
                    });
                    return await r.text();
                } catch (e) {
                    return 'JSERR: ' + ((e && e.message) ? e.message : String(e));
                }
            """, arguments: ["q": xq, "count": Self.postCount]) as? String

            guard let body, !body.hasPrefix("JSERR:") else {
                if let body { log.error("[Xueqiu] posts fetch → \(body, privacy: .public)") }
                return []
            }
            return XueqiuPostParser.parse(jsonString: body)
        } catch {
            log.error("[Xueqiu] posts extract failed: \(Self.errorDetail(error), privacy: .public)")
            return []
        }
    }

    // MARK: - JS error detail (probe idiom)

    /// Pull the underlying JS exception message out of a thrown WebKit error so
    /// the opaque "A JavaScript exception occurred" becomes actionable.
    private static func errorDetail(_ error: Error) -> String {
        let ns = error as NSError
        if let msg = ns.userInfo["WKJavaScriptExceptionMessage"] as? String, !msg.isEmpty {
            let line = ns.userInfo["WKJavaScriptExceptionLineNumber"] as? Int
            return "JS: \(msg)" + (line.map { " (line \($0))" } ?? "")
        }
        return error.localizedDescription
    }

    // MARK: - Navigation await (probe idiom)

    /// Drive the navigation-event sequence to `.finished`, racing a timeout so a
    /// hung headless load still returns. Verbatim shape from the probe's
    /// `awaitNavigation`, collapsed to a Bool (we only need settle/!settle here).
    /// A thrown `WebPage.NavigationError` (incl. -999 cancelled) ⇒ `false`, which
    /// `readyPage` treats as "superseded, retry once".
    private static func awaitFinished<S: AsyncSequence>(
        _ events: S, timeout: Duration
    ) async -> Bool where S.Element == WebPage.NavigationEvent {
        let iterate = Task { @MainActor () -> Bool in
            do {
                for try await event in events {
                    if case .finished = event { return true }
                }
                return false   // stream ended (or cancelled) without finishing
            } catch {
                return false   // WebPage.NavigationError or CancellationError
            }
        }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            iterate.cancel()
        }
        let ok = await iterate.value
        watchdog.cancel()
        return ok
    }
}
