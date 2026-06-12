import Foundation
import WebKit
import TradingFloor
import os

/// The X (Twitter) sibling of `XueqiuLiveScraper`: the WebKit work behind the
/// `BrowserSessionManager`'s X path, split out so the manager stays testable
/// (the manager talks to this small seam; unit tests inject a mock).
///
/// **Why this is shaped differently from the 雪球 scraper.** 雪球 exposes plain
/// same-origin JSON endpoints that auto-attach the session cookie, so its scraper
/// is a `fetch('/statuses/search.json')`. X is the adversarial case: its private
/// GraphQL search needs an unforgeable `x-client-transaction-id` on every request
/// (signed by X's own obfuscated JS), so a raw same-origin `fetch` is NOT a
/// sanctioned path. The VALIDATED, ban-safe technique (proven by `XProbe.searchStock`)
/// is **navigation-driven**: navigate the persistent headless `WebPage` ONCE to the
/// normal human search URL (`/search?q=$SYMBOL&f=live`), let X's OWN JS issue the
/// underlying request, then do ONE `callJavaScript` DOM read of the rendered
/// `<article data-testid="tweet">` nodes. This looks like a person typing a query
/// and sidesteps the transaction-id / queryId problem entirely.
///
/// **The -999 fix (carried over verbatim).** As with 雪球, overlapping navigations
/// on a freshly-built page cancel each other (`NSURLErrorDomain -999`). Here there
/// is exactly ONE long-lived headless page, parked ONCE at `/home`; each per-stock
/// search is the ONE sanctioned navigation away to `/search?q=…` followed by the
/// ONE DOM read. We tolerate a single superseded (-999) nav (X's SPA often
/// redirects the search route) and DOM-read anyway, NEVER retrying — the hard
/// ban-safety contract is exactly one network-driving action per call.
///
/// REUSES the compiler-verified `WebPage` API patterns from `XProbe` /
/// `XueqiuLiveScraper`:
///   • `WKWebsiteDataStore(forIdentifier:)` with a FIXED persistent UUID,
///   • `WebPage.Configuration().websiteDataStore`,
///   • `page.load(_:)` → `some AsyncSequence<NavigationEvent, Error>` driven with
///     `for try await` + a timeout watchdog (failures THROWN as `NavigationError`),
///   • `callJavaScript(_:arguments:)` → optional `Any`,
///   • the self-reporting, null-guarded DOM-read JS + `errorDetail()`.
@available(macOS 26.0, *)
@MainActor
protocol XLiveScraping: Sendable {
    /// Build the visible login page bound to the named persistent store and kick
    /// off a load of `/home` (the logged-in landing surface). Returned page backs
    /// `WebView(page)` — the user signs into X here once (password / 2FA / any
    /// automation challenge, all human-in-the-loop).
    func makeLoginPage() -> WebPage
    /// Cheap logged-in probe via the persistent headless page. X marks its auth
    /// cookies HttpOnly, so we read what JS CAN see (`ct0` cookie) plus a
    /// logged-in DOM marker; both present ⇒ `.valid`, else `.expired`; `.unknown`
    /// if the page couldn't be readied or the probe couldn't settle.
    func probeStatus(timeout: Duration) async -> XueqiuSessionStatus
    /// Recent X discussion posts for a `$SYMBOL` cashtag, via the ONE sanctioned
    /// navigation-driven single-shot search + DOM read. Best-effort: `[]` on
    /// no-session / empty / timeout / error; never throws.
    func searchPosts(cashtag: String, timeout: Duration) async -> [XPost]
}

/// One X (Twitter) discussion post read from the rendered search results. Lives
/// app-side (NOT in the Foundation-only `TradingFloor` package) because — unlike
/// 雪球's `XueqiuPost` — the X path is UI-only: it does NOT flow through a package
/// decorator into the agent's snapshot. It's the same DOM-read shape `XProbe`
/// surfaces (`@handle` + text), reduced to what the Social card renders.
struct XPost: Sendable, Equatable, Identifiable {
    /// Author handle including the leading `@` (e.g. `@elonmusk`); empty when the
    /// `User-Name` block didn't expose one.
    let handle: String
    /// Plain-text tweet body — the `tweetText` node's `innerText`, trimmed.
    let text: String

    /// Stable identity for `ForEach` / `Identifiable`. Composed from handle+text
    /// since the DOM read carries no permalink, so two distinct tweets don't
    /// collide and SwiftUI diffing stays stable across refreshes.
    var id: String { "\(handle)|\(text)" }
}

/// Live, WebKit-backed implementation. Owns the ONE persistent headless `WebPage`
/// (on the named store) parked at `/home`; each per-stock search navigates it ONCE
/// to `/search?q=…&f=live` and does ONE DOM read. Mirrors `XueqiuLiveScraper`'s
/// lazy `readyPage` coalescing so concurrent first-use loads don't double-navigate.
@available(macOS 26.0, *)
@MainActor
final class XLiveScraper: XLiveScraping {

    /// **FIXED** persistent store identifier — the SAME UUID `XProbe` validated,
    /// so the production X path inherits whatever session the user already
    /// established in the dev probe (and vice-versa), and — crucially — so the
    /// visible-login ↔ headless cookie sharing works (both pages must share a
    /// store). It MUST be hardcoded: a fresh UUID per launch would orphan the
    /// cookie jar (losing the login). Distinct from 雪球's jar so the two logins
    /// never read or pollute each other.
    static let storeID = UUID(uuidString: "9F15E06D-2F4D-448B-8B45-7E305C953D17")!

    /// The logged-in landing surface the user signs into and the persistent
    /// headless page parks on. `/home` renders the timeline DOM and is same-origin
    /// with search, so one parked page serves the login + every search without a
    /// second store.
    static let homeURL = URL(string: "https://x.com/home")!

    private let log = Logger(subsystem: "me.impai.wick", category: "XLiveScraper")

    // MARK: - Persistent headless page (the -999 fix)

    /// The ONE long-lived headless page every search runs against. Built + parked
    /// at `/home` on first use, then reused — each search is the ONE sanctioned
    /// navigation away to `/search?q=…`. `nil` until first readied, so `readyPage`
    /// can build it lazily.
    private var dataPage: WebPage?

    /// Coalesces concurrent first-use loads so two searches racing in don't each
    /// kick a `/home` navigation (which would re-introduce the overlapping-nav -999).
    private var readyTask: Task<WebPage?, Never>?

    private func makeStore() -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: Self.storeID)
    }

    func makeLoginPage() -> WebPage {
        var config = WebPage.Configuration()
        config.websiteDataStore = makeStore()
        let page = WebPage(configuration: config)
        log.info("[X] login page bound to store \(Self.storeID.uuidString, privacy: .public)")
        page.load(URLRequest(url: Self.homeURL))
        return page
    }

    /// Return the persistent headless page, parking it ONCE at `/home` if it isn't
    /// ready yet. Tolerates a -999/cancelled (superseded) navigation by retrying
    /// the park once. Concurrent callers coalesce onto one `readyTask`. Returns
    /// `nil` only if the page genuinely couldn't be readied.
    private func readyPage(timeout: Duration) async -> WebPage? {
        if let page = dataPage { return page }   // already parked — reuse, no nav
        if let task = readyTask { return await task.value }

        let task = Task { @MainActor () -> WebPage? in
            defer { self.readyTask = nil }
            var config = WebPage.Configuration()
            config.websiteDataStore = self.makeStore()
            let page = WebPage(configuration: config)

            // Park at /home once. A -999 (cancelled / superseded) is tolerated and
            // retried a single time — past that we give up.
            for attempt in 1...2 {
                let events = page.load(URLRequest(url: Self.homeURL))
                let outcome = await Self.awaitFinished(events, timeout: timeout)
                if outcome { self.dataPage = page; return page }
                self.log.info("[X] /home park attempt \(attempt) did not finish; \(attempt < 2 ? "retrying" : "giving up")")
            }
            return nil
        }
        readyTask = task
        return await task.value
    }

    // MARK: - Status probe (session check on the persistent page)

    func probeStatus(timeout: Duration) async -> XueqiuSessionStatus {
        guard let page = await readyPage(timeout: timeout) else { return .unknown }
        do {
            // Self-reporting JS (XProbe's session-check pattern). X marks the auth
            // cookies HttpOnly, so `document.cookie` won't expose `auth_token`. We
            // read what JS CAN see — the `ct0` cookie (present for any session) —
            // plus a logged-in DOM marker X renders only when authed. Both ⇒ live.
            let verdict = try await page.callJavaScript("""
                try {
                    const ck = document.cookie || '';
                    const hasCt0 = /(?:^|;\\s*)ct0=/.test(ck);
                    const marker = document.querySelector('[data-testid="SideNav_AccountSwitcher_Button"]')
                                || document.querySelector('[data-testid="AppTabBar_Home_Link"]')
                                || document.querySelector('[data-testid="tweetButtonInline"]')
                                || document.querySelector('[aria-label="Home timeline"]');
                    if (hasCt0 && marker) return 'valid';
                    return 'expired';
                } catch (e) {
                    return 'JSERR: ' + ((e && e.message) ? e.message : String(e));
                }
            """) as? String
            switch verdict {
            case .some("valid"):   return .valid
            case .some("expired"): return .expired
            default:
                log.error("[X] status probe → \(verdict ?? "nil", privacy: .public)")
                return .unknown
            }
        } catch {
            log.error("[X] status probe failed: \(Self.errorDetail(error), privacy: .public)")
            return .unknown
        }
    }

    // MARK: - Per-stock search (single-shot, ban-safe, navigation-driven)

    func searchPosts(cashtag: String, timeout: Duration) async -> [XPost] {
        let trimmed = cashtag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let page = await readyPage(timeout: timeout) else { return [] }

        // Build the normal, human-looking live-search URL. `f=live` = Latest tab;
        // `src=typed_query` mirrors what X sets when a person types into search.
        // Percent-encode strictly for the `q=` VALUE: Foundation's `.urlQueryAllowed`
        // still permits sub-delims (`&`, `=`, `+`, `$`, …) that would corrupt the
        // param, so we subtract those — the cashtag's `$` and any spaces get escaped.
        var valueAllowed = CharacterSet.urlQueryAllowed
        valueAllowed.remove(charactersIn: "&=+$#?/;:,@")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? trimmed
        guard let url = URL(string: "https://x.com/search?q=\(encoded)&src=typed_query&f=live") else {
            return []
        }
        log.info("[X] searchPosts: single-shot nav → \(url.absoluteString, privacy: .public)")

        // ── The ONE network-driving navigation ─────────────────────────────────
        // Exactly one `load(_:)` away from /home. Tolerate a single superseded
        // (-999) nav and DOM-read anyway (X's SPA often redirects the search
        // route); NEVER retry — the hard ban-safety contract is one action/call.
        let events = page.load(URLRequest(url: url))
        let finished = await Self.awaitFinished(events, timeout: timeout)
        if !finished {
            log.info("[X] searchPosts: nav did not cleanly finish (superseded/timeout); reading rendered DOM anyway")
        }

        // ── The ONE DOM read of the rendered search results ────────────────────
        // Same selectors as XProbe Path A: `article[data-testid="tweet"]` → per
        // node `[data-testid="tweetText"]` innerText + the `@handle` from the
        // `[data-testid="User-Name"]` block. Self-reporting, null-guarded JS.
        do {
            let domObj = try await page.callJavaScript("""
                try {
                    const arts = document.querySelectorAll('article[data-testid="tweet"]');
                    // DIAGNOSTIC signals so an empty result is explainable: how many
                    // tweet nodes the DOM had, the URL we actually landed on (a login
                    // wall redirects away from /search), and whether a login prompt
                    // is on screen.
                    const _diag = {
                        arts: arts.length,
                        url: location.href,
                        loginWall: !!document.querySelector('[data-testid="loginButton"], [href="/login"], input[name="text"]'),
                        bodyHint: (document.body ? document.body.innerText.slice(0, 120) : '')
                    };
                    const out = [];
                    for (let i = 0; i < arts.length && out.length < limit; i++) {
                        const a = arts[i];
                        const textEl = a.querySelector('[data-testid="tweetText"]');
                        const text = textEl ? (textEl.innerText || '').trim() : '';
                        let handle = '';
                        const nameBlock = a.querySelector('[data-testid="User-Name"]');
                        if (nameBlock) {
                            const spans = nameBlock.querySelectorAll('span');
                            for (const s of spans) {
                                const t = (s.innerText || '').trim();
                                if (t.startsWith('@')) { handle = t; break; }
                            }
                        }
                        if (text || handle) { out.push({ handle: handle, text: text.slice(0, 280) }); }
                    }
                    return { posts: out, diag: _diag };
                } catch (e) {
                    return { error: ((e && e.message) ? e.message : String(e)) };
                }
            """, arguments: ["limit": Self.postCount]) as? [String: Any]

            if let jsErr = domObj?["error"] as? String {
                log.error("[X] searchPosts DOM read JSERR: \(jsErr, privacy: .public)")
                return []
            }
            let rawPosts = (domObj?["posts"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            let posts = rawPosts.compactMap { raw -> XPost? in
                let handle = (raw["handle"] as? String) ?? ""
                let text = (raw["text"] as? String) ?? ""
                guard !text.isEmpty || !handle.isEmpty else { return nil }
                return XPost(handle: handle, text: text)
            }
            // DIAGNOSTIC: when empty, surface why — tweet-node count, landed URL,
            // and login-wall flag distinguish "0 results" from "redirected to login
            // / not rendered yet".
            if posts.isEmpty, let diag = domObj?["diag"] as? [String: Any] {
                let arts = diag["arts"] as? Int ?? -1
                let url = diag["url"] as? String ?? "?"
                let wall = diag["loginWall"] as? Bool ?? false
                let hint = diag["bodyHint"] as? String ?? ""
                log.error("[X] EMPTY posts — arts=\(arts, privacy: .public) loginWall=\(wall, privacy: .public) url=\(url, privacy: .public) hint=\(hint, privacy: .public)")
            } else {
                log.info("[X] searchPosts → \(posts.count) posts")
            }
            return posts
        } catch {
            log.error("[X] searchPosts DOM read failed: \(Self.errorDetail(error), privacy: .public)")
            return []
        }
    }

    /// How many search results to surface per stock. The Social card list is the
    /// only consumer; this just bounds the DOM read.
    static let postCount = 20

    // MARK: - JS error detail (probe idiom)

    /// Pull the underlying JS exception message out of a thrown WebKit error so
    /// the opaque "A JavaScript exception occurred" becomes actionable. (Verbatim
    /// idiom from `XProbe` / `XueqiuLiveScraper`.)
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
    /// hung headless load still returns. Verbatim shape from `XueqiuLiveScraper`,
    /// collapsed to a Bool (we only need settle/!settle here). A thrown
    /// `WebPage.NavigationError` (incl. -999 cancelled) ⇒ `false`, which the
    /// callers treat as "superseded / didn't settle — read whatever rendered".
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
