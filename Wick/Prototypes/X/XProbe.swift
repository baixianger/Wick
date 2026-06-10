import Foundation
import WebKit
import os

/// **Dev-only probe** mirroring `XueqiuProbe`, but pointed at the HARD target:
/// X (Twitter). Where 雪球 was the validated, friendly first target (plain JSON
/// endpoints that auto-attach the session cookie), X is the adversarial case —
/// it runs aggressive automation detection, and its private GraphQL API demands
/// a triad of headers on every request:
///
///   • `authorization: Bearer <public web token>` — a long-lived, well-known
///     anonymous bearer the web client ships with (NOT per-user; it gates the
///     API surface, not the account).
///   • `x-csrf-token: <ct0 cookie>` — the CSRF double-submit token, mirrored
///     from the `ct0` cookie the logged-in session holds.
///   • `x-client-transaction-id: <per-request value>` — a signature X's own
///     obfuscated JS computes per request from the endpoint path + a rotating
///     animation key baked into the page. There is no public way to mint this
///     outside X's JS; its absence is the linchpin gap this probe MEASURES.
///
/// So the probe does NOT assume X "works". It TRIES MULTIPLE PATHS on one
/// persistent, already-logged-in headless `WebPage` and HONESTLY REPORTS which
/// is reachable:
///
///   • **Path A — DOM read** (most likely to succeed): scrape the rendered home
///     timeline `<article data-testid="tweet">` nodes the SPA already painted.
///     This needs no special headers — it reads what the page itself rendered,
///     so if the session is live and the SPA settled, tweets are right there.
///   • **Path B — API attempt** (documents the gap): a same-origin `fetch` to an
///     X GraphQL read endpoint with the Bearer + `x-csrf-token` triad MINUS the
///     `x-client-transaction-id` we can't forge. We capture the exact HTTP
///     status / error body so the gap is recorded, not guessed (commonly 404 on
///     a stale queryId, or 401/403 on the missing transaction id).
///
/// ROBUSTNESS lesson carried over from the production scraper + `XueqiuProbe`:
/// keep ONE persistent headless page, load it ONCE at a light page, and run
/// every per-call `callJavaScript` WITHOUT re-navigating — re-navigation on each
/// call caused `NSURLErrorDomain -999` (cancelled) in practice. Here the
/// persistent page sits at `https://x.com/home`; the probe never reloads it.
///
/// Everything is `@available(macOS 26.0, *)` (`WebPage` / `WebView` are
/// 26-SDK-new) and `@MainActor` (`WebPage` is main-actor-bound).
@available(macOS 26.0, *)
@MainActor
@Observable
final class XProbe {

    // MARK: Stable store identity

    /// **FIXED** persistent store identifier — a NEW UUID, distinct from 雪球's,
    /// so the X cookie jar is isolated from the 雪球 one. As with the 雪球 probe
    /// it MUST be hardcoded: a fresh UUID per launch would orphan the previous
    /// jar (losing the login) and would also break the visible-login ↔ headless
    /// cookie sharing, since the two pages would no longer share a store. Chosen
    /// once, by hand; never regenerate.
    static let storeID = UUID(uuidString: "9F15E06D-2F4D-448B-8B45-7E305C953D17")!

    /// The home timeline the user logs into in the visible `WebView`, and the
    /// light-ish page the persistent headless page parks on. `/home` is the
    /// logged-in landing surface — it both renders the timeline DOM (Path A) and
    /// is same-origin with the GraphQL API (Path B), so one parked page serves
    /// both paths without ever re-navigating.
    static let homeURL = URL(string: "https://x.com/home")!

    /// The well-known **public web bearer** the X web client ships with. It is
    /// anonymous (not tied to any account) and gates the API surface; per-user
    /// auth rides on the session cookie (`auth_token`) + `ct0`/`x-csrf-token`.
    /// Hardcoded here exactly as the web client uses it (the `%3D` is a real
    /// URL-encoded `=` inside the token and is left as-is).
    static let publicBearer = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"

    private let log = Logger(subsystem: "me.impai.wick", category: "XProbe")

    /// The visible login page — built once in `init` and held so the same
    /// `WebPage` instance backs the on-screen `WebView` across redraws. The user
    /// logs into X here once (password / 2FA / any automation challenge — all
    /// human-in-the-loop in the visible view). `@ObservationIgnored` for the same
    /// reason as the 雪球 probe: the reference never changes, and `@Observable`'s
    /// macro can't synthesize an init-accessor for a non-trivially-initialized
    /// stored property.
    @ObservationIgnored private(set) var loginPage: WebPage

    /// The **persistent headless page**, on the SAME store, parked ONCE at
    /// `/home`. Every `probe()` call reuses this instance and does per-call
    /// `callJavaScript` WITHOUT re-navigating (the `-999` lesson). Built in
    /// `init`; the initial `load` is fired there and never repeated.
    @ObservationIgnored private(set) var headlessPage: WebPage

    /// `true` once the persistent page's initial `/home` navigation has settled
    /// at least once, so `probe()` can note "page wasn't ready" vs a real empty
    /// timeline. Best-effort — the probe still runs if this never flips.
    @ObservationIgnored private var headlessReady = false

    init() {
        loginPage = Self.makeLoginPage(log: log)
        headlessPage = Self.makeHeadlessPage(log: log)
    }

    // MARK: - Login page (visible WebView)

    /// Builds the visible login `WebPage`, bound to the named persistent store.
    /// The user logs into X here once; WebKit writes `auth_token` + `ct0` into
    /// the store keyed by `storeID`. Wick stores nothing — no password, no
    /// token; only the store identifier (a UUID), never a cookie. `static` so
    /// `init` can call it before `self` is fully formed.
    static func makeLoginPage(log: Logger) -> WebPage {
        var config = WebPage.Configuration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        let page = WebPage(configuration: config)
        log.info("[XProbe] makeLoginPage: bound to store \(storeID.uuidString, privacy: .public)")
        page.load(URLRequest(url: homeURL))
        return page
    }

    /// Builds the persistent headless `WebPage` on the SAME store and fires its
    /// one-and-only `/home` load. Crucially we DON'T await the returned event
    /// sequence here (we're in a sync `static` used from `init`); `probe()`
    /// runs whenever the user clicks, by which point the page has typically
    /// settled. No `WebView` ever wraps this page — it stays off-screen.
    static func makeHeadlessPage(log: Logger) -> WebPage {
        var config = WebPage.Configuration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        let page = WebPage(configuration: config)
        log.info("[XProbe] makeHeadlessPage: bound to store \(storeID.uuidString, privacy: .public), parking at \(homeURL.absoluteString, privacy: .public)")
        page.load(URLRequest(url: homeURL))
        return page
    }

    /// Re-load the visible login page (e.g. after the user clears it) so they
    /// can sign into X again without rebuilding the whole probe.
    func reloadLogin() {
        log.info("[XProbe] reloadLogin")
        loginPage.load(URLRequest(url: Self.homeURL))
    }

    /// Re-park the persistent headless page at `/home`. Exposed so the dev UI can
    /// force a fresh render AFTER the user has logged in (the page was parked at
    /// `init`, before login, so its first paint is the logged-out wall). Awaits
    /// the settle so the caller can sequence a `probe()` right after. This is the
    /// ONE sanctioned re-navigation — done explicitly by the user, not per call.
    func reparkHeadless(timeout: Duration = .seconds(25)) async {
        log.info("[XProbe] reparkHeadless: reloading \(Self.homeURL.absoluteString, privacy: .public)")
        let events = headlessPage.load(URLRequest(url: Self.homeURL))
        let outcome = await awaitNavigation(events, timeout: timeout)
        headlessReady = (outcome == .finished)
        log.info("[XProbe] reparkHeadless outcome: \(outcome.description, privacy: .public)")
    }

    // MARK: - Probe result

    /// Result of one multi-path probe run. Each path self-reports independently
    /// so the dev UI can show what's reachable (DOM vs API) at a glance.
    struct XProbeResult: Sendable {
        /// `true` = `auth_token` + `ct0` cookies present (session live);
        /// `false` = at least one missing (likely logged out / wall);
        /// `nil` = the session-check JS itself failed.
        var loggedIn: Bool?
        /// **Path A** — number of `<article data-testid="tweet">` nodes the
        /// rendered home timeline exposed. 0 ⇒ nothing rendered (logged out, SPA
        /// not settled, or X changed the selector).
        var domTweetCount: Int
        /// **Path A** — a few sample tweet texts (author handle + text), for
        /// eyeballing that real per-user content was reached.
        var domSamples: [String]
        /// **Path B** — readable HTTP status of the GraphQL `fetch`
        /// (`"http 200"`, `"http 404"`, `"http 403"`, or `"JSERR: …"`).
        var apiStatus: String
        /// **Path B** — first slice of the API response body (JSON or error),
        /// so the gap (missing `x-client-transaction-id`, stale queryId, …) is
        /// recorded verbatim rather than inferred.
        var apiSample: String
        /// Any cross-cutting error (page never ready, session-check throw, …),
        /// surfaced verbatim.
        var error: String?
    }

    // MARK: - The probe (Path A + Path B on the persistent page)

    /// Run the session check, then Path A (DOM), then Path B (API) on the ONE
    /// persistent headless page, WITHOUT re-navigating. Each step null-guards its
    /// JS and self-reports faults as readable strings so a runtime fault surfaces
    /// as a value, not an opaque host exception.
    ///
    /// - Parameter screenName: optional handle (no `@`) to target Path B's
    ///   `UserByScreenName` GraphQL read. Empty ⇒ Path B hits the public bearer
    ///   surface with a benign query and reports whatever X returns.
    func probe(screenName: String = "") async -> XProbeResult {
        log.info("[XProbe] probe: on persistent headless page (no re-nav), screenName=\(screenName.isEmpty ? "<none>" : screenName, privacy: .public)")

        var result = XProbeResult(loggedIn: nil,
                                  domTweetCount: 0,
                                  domSamples: [],
                                  apiStatus: "not attempted",
                                  apiSample: "",
                                  error: nil)

        if !headlessReady {
            // Not fatal — the page may have settled without us awaiting it (the
            // init load isn't awaited). Note it so an empty result is explicable.
            log.info("[XProbe] probe: headless page not marked ready (init load not awaited or still loading)")
        }

        // ── Session check ──────────────────────────────────────────────────
        // X marks the auth cookies HttpOnly, so `document.cookie` won't expose
        // `auth_token`. We read what JS *can* see: `ct0` (NOT HttpOnly, present
        // for any session) plus a logged-in DOM marker (the primary nav's
        // account switcher / the composer). Presence of `ct0` AND a logged-in
        // marker ⇒ session live. Self-reporting JS, null-guarded.
        do {
            let verdict = try await headlessPage.callJavaScript("""
                try {
                    const ck = document.cookie || '';
                    const hasCt0 = /(?:^|;\\s*)ct0=/.test(ck);
                    // Logged-in DOM markers X renders only when authed.
                    const marker = document.querySelector('[data-testid="SideNav_AccountSwitcher_Button"]')
                                || document.querySelector('[data-testid="AppTabBar_Home_Link"]')
                                || document.querySelector('[data-testid="tweetButtonInline"]')
                                || document.querySelector('[aria-label="Home timeline"]');
                    if (hasCt0 && marker)  return 'yes';
                    if (hasCt0 && !marker) return 'no:ct0-but-no-marker';
                    return 'no:no-ct0';
                } catch (e) {
                    return 'JSERR: ' + ((e && e.message) ? e.message : String(e));
                }
            """) as? String
            switch verdict {
            case .some(let v) where v.hasPrefix("yes"): result.loggedIn = true
            case .some(let v) where v.hasPrefix("no"):  result.loggedIn = false
            case .none:                                 result.loggedIn = nil
            default:                                    // "JSERR: …"
                result.loggedIn = nil
                if result.error == nil { result.error = "session check \(verdict ?? "nil")" }
            }
            log.info("[XProbe] session check → \(verdict ?? "nil", privacy: .public)")
        } catch {
            let detail = Self.errorDetail(error)
            log.error("[XProbe] session check failed: \(detail, privacy: .public)")
            if result.error == nil { result.error = "session check: \(detail)" }
        }

        // ── Path A — DOM read of the rendered home timeline ────────────────
        // Query the painted `<article data-testid="tweet">` nodes; within each
        // pull `[data-testid="tweetText"]`'s innerText + the author handle (the
        // `[data-testid="User-Name"]` block's last `@…` span). Returns count +
        // up to 5 samples. This is the path most likely to succeed: no special
        // headers, just whatever the SPA already rendered for this user.
        do {
            let domObj = try await headlessPage.callJavaScript("""
                try {
                    const arts = document.querySelectorAll('article[data-testid="tweet"]');
                    const samples = [];
                    for (let i = 0; i < arts.length && samples.length < 5; i++) {
                        const a = arts[i];
                        const textEl = a.querySelector('[data-testid="tweetText"]');
                        const text = textEl ? (textEl.innerText || '').trim() : '';
                        // Author handle: the User-Name block holds one or more
                        // spans; the @handle is the span starting with '@'.
                        let handle = '';
                        const nameBlock = a.querySelector('[data-testid="User-Name"]');
                        if (nameBlock) {
                            const spans = nameBlock.querySelectorAll('span');
                            for (const s of spans) {
                                const t = (s.innerText || '').trim();
                                if (t.startsWith('@')) { handle = t; break; }
                            }
                        }
                        if (text || handle) {
                            samples.push((handle ? handle + ' ' : '') + text.slice(0, 240));
                        }
                    }
                    return { count: arts.length, samples: samples };
                } catch (e) {
                    return { error: ((e && e.message) ? e.message : String(e)) };
                }
            """) as? [String: Any]

            if let jsErr = domObj?["error"] as? String {
                if result.error == nil { result.error = "Path A JSERR: \(jsErr)" }
            } else {
                result.domTweetCount = (domObj?["count"] as? Int) ?? 0
                result.domSamples = (domObj?["samples"] as? [Any])?.compactMap { $0 as? String } ?? []
                log.info("[XProbe] Path A (DOM) → \(result.domTweetCount) tweet nodes, \(result.domSamples.count) samples")
            }
        } catch {
            let detail = Self.errorDetail(error)
            log.error("[XProbe] Path A (DOM) failed: \(detail, privacy: .public)")
            if result.error == nil { result.error = "Path A (DOM): \(detail)" }
        }

        // ── Path B — API attempt (documents the gap) ───────────────────────
        // Same-origin `fetch` to an X GraphQL read endpoint with the
        // Bearer + `x-csrf-token` + `x-twitter-active-user` triad — but MINUS
        // the `x-client-transaction-id` we cannot forge. We target
        // `UserByScreenName` (a simple read keyed by a handle) when one is
        // given, else `HomeTimeline`. queryIds rotate; the hardcoded ones below
        // may be stale — that's the POINT: we capture the exact status/body so
        // the failure mode (404 stale-id vs 401/403 missing-transaction-id vs a
        // real 200) is recorded honestly. We ALSO try to read X's own bearer
        // from a page global first, falling back to our hardcoded public one.
        let (status, sample) = await attemptApi(screenName: screenName)
        result.apiStatus = status
        result.apiSample = sample
        log.info("[XProbe] Path B (API) → \(status, privacy: .public)")

        return result
    }

    /// Path B implementation, split out for readability. Builds the GraphQL URL,
    /// reads `ct0` from `document.cookie` for the CSRF header, fires the `fetch`
    /// with `credentials:'include'`, and returns `(readableStatus, bodySlice)`.
    /// Deliberately does NOT supply `x-client-transaction-id` — its absence is
    /// the measured gap. Hardcoded queryIds are honestly labelled as possibly
    /// stale; whatever X returns is reported verbatim.
    private func attemptApi(screenName: String) async -> (String, String) {
        // Known (as of writing — may be stale) GraphQL operation paths. queryIds
        // are the volatile bit; if X has rotated them this 404s, which the probe
        // reports rather than hides.
        let userByScreenNameId = "G3KGOASz96M-Qu0nwmGXNg"   // UserByScreenName
        let homeTimelineId = "HJFjzBgCs16TqxewQOeLNg"        // HomeTimeline

        do {
            let obj = try await headlessPage.callJavaScript("""
                try {
                    const ck = document.cookie || '';
                    const m = ck.match(/(?:^|;\\s*)ct0=([^;]+)/);
                    const ct0 = m ? m[1] : '';

                    // Prefer X's own in-page bearer if a global exposes it; else
                    // fall back to the well-known public web bearer we ship.
                    let bearer = 'Bearer ' + decodeURIComponent(fallbackBearer);

                    let url, body;
                    if (sn && sn.length) {
                        const vars = { screen_name: sn, withSafetyModeUserFields: true };
                        const feats = {
                            hidden_profile_likes_enabled: true,
                            hidden_profile_subscriptions_enabled: true,
                            responsive_web_graphql_exported_tweet_ids_enabled: false,
                            subscriptions_verification_info_is_identity_verified_enabled: true,
                            subscriptions_verification_info_verified_since_enabled: true,
                            highlights_tweets_tab_ui_enabled: true,
                            responsive_web_twitter_article_notes_tab_enabled: true,
                            subscriptions_feature_can_gift_premium: true,
                            creator_subscriptions_tweet_preview_api_enabled: true,
                            responsive_web_graphql_skip_user_profile_image_extensions_enabled: false,
                            responsive_web_graphql_timeline_navigation_enabled: true
                        };
                        url = 'https://x.com/i/api/graphql/' + userByName + '/UserByScreenName'
                            + '?variables=' + encodeURIComponent(JSON.stringify(vars))
                            + '&features=' + encodeURIComponent(JSON.stringify(feats));
                    } else {
                        const vars = { count: 5, includePromotedContent: false, withCommunity: false };
                        const feats = { responsive_web_graphql_timeline_navigation_enabled: true };
                        url = 'https://x.com/i/api/graphql/' + homeTl + '/HomeTimeline'
                            + '?variables=' + encodeURIComponent(JSON.stringify(vars))
                            + '&features=' + encodeURIComponent(JSON.stringify(feats));
                    }

                    const headers = {
                        'authorization': bearer,
                        'x-csrf-token': ct0,
                        'x-twitter-active-user': 'yes',
                        'x-twitter-auth-type': 'OAuth2Session',
                        'content-type': 'application/json'
                        // NOTE: deliberately NO 'x-client-transaction-id' — we
                        // cannot forge X's per-request signed value. Its absence
                        // is the gap this probe measures.
                    };

                    const r = await fetch(url, { method: 'GET', credentials: 'include', headers });
                    const text = await r.text();
                    let kind = 'text';
                    try { JSON.parse(text); kind = 'json'; } catch (e) {}
                    return { status: r.status, kind: kind, len: text.length, sample: text.slice(0, 700) };
                } catch (e) {
                    return { error: ((e && e.message) ? e.message : String(e)) };
                }
            """, arguments: [
                "sn": screenName.trimmingCharacters(in: .whitespaces),
                "userByName": userByScreenNameId,
                "homeTl": homeTimelineId,
                "fallbackBearer": Self.publicBearer
            ]) as? [String: Any]

            if let jsErr = obj?["error"] as? String {
                return ("JSERR: \(jsErr)", "")
            }
            let status = (obj?["status"] as? Int) ?? -1
            let kind = (obj?["kind"] as? String) ?? "?"
            let len = (obj?["len"] as? Int) ?? 0
            let sample = (obj?["sample"] as? String) ?? ""
            return ("http \(status) (\(kind), \(len) chars)", sample)
        } catch {
            return ("threw: \(Self.errorDetail(error))", "")
        }
    }

    /// Pull the underlying JS exception message (+ line) out of a thrown WebKit
    /// error so the opaque "A JavaScript exception occurred" becomes actionable.
    /// Falls back to `localizedDescription`. (Verbatim from `XueqiuProbe`.)
    private static func errorDetail(_ error: Error) -> String {
        let ns = error as NSError
        if let msg = ns.userInfo["WKJavaScriptExceptionMessage"] as? String, !msg.isEmpty {
            let line = ns.userInfo["WKJavaScriptExceptionLineNumber"] as? Int
            return "JS: \(msg)" + (line.map { " (line \($0))" } ?? "")
        }
        return error.localizedDescription
    }

    // MARK: - Navigation awaiting

    /// Outcome of awaiting a single navigation. (Verbatim idiom from
    /// `XueqiuProbe` — `Equatable` so `reparkHeadless` can compare `== .finished`.)
    private enum NavOutcome: CustomStringConvertible, Equatable {
        case finished
        case failed(String)
        case timedOut(Duration)

        var description: String {
            switch self {
            case .finished:        return "finished"
            case .failed(let m):   return "failed: \(m)"
            case .timedOut(let d): return "timed out after \(d)"
            }
        }
    }

    /// Drive the navigation-event sequence returned by `WebPage.load(_:)` until
    /// `.finished`, racing a timeout so a hung headless load still returns a
    /// verdict. Verbatim idiom from `XueqiuProbe`: the shipping macOS 26
    /// `load(_:)` RETURNS the event `AsyncSequence` (no `NavigationID` /
    /// `currentNavigationEvent`), yields `.startedProvisionalNavigation →
    /// .committed → .finished`, and THROWS `WebPage.NavigationError` on failure.
    private func awaitNavigation<S: AsyncSequence>(
        _ events: S,
        timeout: Duration
    ) async -> NavOutcome where S.Element == WebPage.NavigationEvent {
        let iterate = Task { @MainActor () -> NavOutcome in
            do {
                for try await event in events {
                    switch event {
                    case .finished:
                        return .finished
                    case .startedProvisionalNavigation,
                         .receivedServerRedirect,
                         .committed:
                        continue
                    @unknown default:
                        continue
                    }
                }
                return Task.isCancelled
                    ? .timedOut(timeout)
                    : .failed("navigation stream ended without finishing")
            } catch is CancellationError {
                return .timedOut(timeout)
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            iterate.cancel()
        }

        let outcome = await iterate.value
        watchdog.cancel()
        return outcome
    }
}
