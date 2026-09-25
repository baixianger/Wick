import Foundation
import WebKit
import os

/// **Dev-only probe** for the WWDC25 SwiftUI WebKit (`WebPage`) BYO-cookie
/// scraping path. NOT wired into the production data chain — it exists solely
/// to let a human validate the two linchpin unknowns from
/// `docs/research/webpage-byo-scraping-feasibility.md` (§9, open questions 1–2)
/// before any real `BrowserSessionManager` is built on top of them:
///
///   (A) **Cross-store cookie visibility.** Does a *headless* `WebPage` bound
///       to a named `WKWebsiteDataStore(forIdentifier:)` reliably see the auth
///       cookie written by a *visible* login `WebView` that used the SAME store
///       identifier? (Should hold — it's one store — but it's the linchpin of
///       Mode 1, so we verify it on real macOS 26 rather than assume it.)
///
///   (B) **Headless SPA render.** Does a headless (never-on-screen) `WebPage`
///       actually run 雪球's JS and settle navigation to `.finished` so
///       `callJavaScript` can read rendered discussion/post text — or does the
///       SPA need an attached/visible view to paint?
///
/// The probe drives 雪球 (Xueqiu) specifically because it's the research doc's
/// chosen lowest-risk first target (§8): A-share retail sentiment, hot-post
/// section is plain DOM text, and the session is friendly to a logged-in
/// headless drive (unlike X — see §6.1).
///
/// Everything here is `@available(macOS 26.0, *)` because `WebPage` / `WebView`
/// are 26-SDK-new, and `@MainActor` because `WebPage` is main-actor-bound.
@available(macOS 26.0, *)
@MainActor
@Observable
final class XueqiuProbe {

    // MARK: Stable store identity

    /// **FIXED** persistent store identifier. `WKWebsiteDataStore(forIdentifier:)`
    /// keys an on-disk, app-isolated cookie jar by this UUID; recreating the
    /// store with the *same* UUID on relaunch is what restores the logged-in
    /// session. It MUST be hardcoded — generating a fresh UUID per launch would
    /// silently orphan the previous jar and break persistence (and would also
    /// break linchpin A, since the login view and the headless probe would no
    /// longer share a store). Chosen once, by hand; never regenerate.
    static let storeID = UUID(uuidString: "7C9E6B1A-3D42-4F58-9A0C-2E1F8B4D6A77")!

    /// 雪球 origin the user logs into in the visible `WebView`.
    static let loginURL = URL(string: "https://xueqiu.com")!

    private let log = Logger(subsystem: "me.impai.wick", category: "XueqiuProbe")

    /// The visible login page — built once in `init` and held so the same
    /// `WebPage` instance backs the on-screen `WebView` across redraws.
    /// `@ObservationIgnored`: the reference never changes, and `@Observable`'s
    /// macro cannot synthesize an init-accessor for a non-trivially-initialized
    /// stored property (a `lazy` here fails to compile). Headless extracts use a
    /// *separate* `WebPage` (below) so we genuinely exercise the cross-instance
    /// / cross-store cookie path of linchpin A, not one page that trivially
    /// "sees its own cookies".
    @ObservationIgnored private(set) var loginPage: WebPage

    init() {
        loginPage = Self.makeLoginPage(log: log)
    }

    // MARK: - Login page (visible WebView)

    /// Builds the `WebPage` for the visible login `WebView`, bound to the named
    /// persistent store. The user logs in here once (password / SMS 2FA /
    /// captcha — all human-in-the-loop in the visible view); WebKit writes the
    /// auth cookie into the store keyed by `storeID`. Wick stores nothing — no
    /// password, no token; only the store identifier (a UUID), never the cookie.
    /// `static` so `init` can call it before `self` is fully formed.
    static func makeLoginPage(log: Logger) -> WebPage {
        var config = WebPage.Configuration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        let page = WebPage(configuration: config)
        log.info("[XueqiuProbe] makeLoginPage: bound to store \(storeID.uuidString, privacy: .public)")
        page.load(URLRequest(url: loginURL))
        return page
    }

    /// Re-load the login page (e.g. after the user clears it) so they can
    /// sign in again without rebuilding the whole probe.
    func reloadLogin() {
        log.info("[XueqiuProbe] reloadLogin")
        loginPage.load(URLRequest(url: Self.loginURL))
    }

    // MARK: - Headless extract (the actual probe)

    /// Result of one headless extraction attempt. Deliberately captures *both*
    /// linchpins so the dev UI can report them independently:
    ///   • `loggedIn` answers A (did the headless page inherit the cookie?).
    ///   • a non-error `navigation` + non-empty `textSample` answers B (did the
    ///     headless SPA actually render?).
    struct ProbeResult: Sendable {
        /// `true` = logged-in DOM marker found; `false` = login wall detected;
        /// `nil` = couldn't tell (probe JS failed or page never settled).
        var loggedIn: Bool?
        /// Human-readable navigation outcome (`"finished"`, `"failed: …"`,
        /// `"timed out after Ns"`, …).
        var navigation: String
        /// Final URL the headless page settled on — a redirect to a login URL
        /// is itself evidence of a stale/absent session.
        var finalURL: String?
        /// Total characters of discussion text pulled (0 ⇒ nothing rendered or
        /// selectors missed).
        var textLength: Int
        /// First ~600 chars of the extracted text, for eyeballing in the UI.
        var textSample: String
        /// Any thrown error, surfaced verbatim.
        var error: String?
    }

    /// Map an A-share numeric code to the 雪球 symbol form. 雪球 prefixes the
    /// exchange: Shanghai `600519` → `SH600519`, Shenzhen `000001` → `SZ000001`.
    /// `6`-leading codes are Shanghai; everything else here is treated as
    /// Shenzhen (sufficient for the probe — production symbol resolution lives
    /// in the package's `CNSymbol`).
    static func xueqiuSymbol(forAShareCode code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces).uppercased()
        if trimmed.hasPrefix("SH") || trimmed.hasPrefix("SZ") { return trimmed }
        return (trimmed.hasPrefix("6") ? "SH" : "SZ") + trimmed
    }

    /// Spin a **separate headless** `WebPage` on the **same named store**, load
    /// the 雪球 stock page, await `.finished`, then `callJavaScript` to (a)
    /// report logged-in-ness and (b) pull visible discussion text.
    ///
    /// - Parameter symbol: e.g. `"SH600519"` (贵州茅台). Use
    ///   `xueqiuSymbol(forAShareCode:)` to derive it from a raw A-share code.
    /// - Parameter timeout: navigation settle budget. Headless SPA renders can
    ///   lag; default 20s is generous but bounded so a hung load still returns.
    func extractDiscussion(symbol: String,
                           timeout: Duration = .seconds(20)) async -> ProbeResult {
        let url = URL(string: "https://xueqiu.com/S/\(symbol)")!
        log.info("[XueqiuProbe] extractDiscussion: headless page on store \(Self.storeID.uuidString, privacy: .public), url \(url.absoluteString, privacy: .public)")

        // SEPARATE headless page on the SAME store — this is what exercises
        // linchpin A (cross-instance cookie sharing). No WebView ever wraps it.
        var config = WebPage.Configuration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID)
        let page = WebPage(configuration: config)

        var result = ProbeResult(loggedIn: nil,
                                 navigation: "starting",
                                 finalURL: nil,
                                 textLength: 0,
                                 textSample: "",
                                 error: nil)

        // 1) Load + await navigation settle (or timeout).
        //
        // API NOTE: the shipping macOS 26 `WebPage.load(_:)` RETURNS the
        // navigation-event AsyncSequence directly (it does NOT return a
        // `NavigationID` you later match against a `currentNavigationEvent`
        // property — that was the research-doc assumption and is wrong). The
        // sequence yields `.startedProvisionalNavigation → .committed →
        // .finished`, and THROWS a `WebPage.NavigationError` on failure instead
        // of emitting a `.failed` case. So we iterate the returned sequence.
        log.info("[XueqiuProbe] load issued for \(url.absoluteString, privacy: .public)")
        let events = page.load(URLRequest(url: url))

        let outcome = await awaitNavigation(events, timeout: timeout)
        result.navigation = outcome.description
        log.info("[XueqiuProbe] navigation outcome: \(outcome.description, privacy: .public)")

        if case .failed(let message) = outcome {
            result.error = message
            // Still try the JS probes below — a failed nav can sometimes leave a
            // usable DOM — but record the failure.
        }

        result.finalURL = page.url?.absoluteString

        // 2) Session probe (linchpin A) — via the JSON API, NOT the DOM.
        //    Per the user's snowball-cli research, 雪球 exposes same-origin JSON
        //    endpoints that auto-attach the session cookie. We `fetch` a small
        //    authenticated endpoint from inside the loaded xueqiu.com page: a
        //    well-formed JSON body with no `error_code` ⇒ the headless page
        //    inherited a working session from the visible login (A holds). This
        //    drops brittle SPA DOM selectors entirely — and makes the old
        //    linchpin B ("does the SPA paint headless?") MOOT, because the API
        //    path never needs the SPA rendered, only origin + cookie + `fetch`.
        //    The JS self-reports ("yes…"/"no…"/"JSERR: …") so a runtime fault
        //    surfaces as a readable value, not the opaque host exception.
        do {
            let verdict = try await page.callJavaScript("""
                try {
                    const r = await fetch('/statuses/hots.json?a=1&count=1&page=1&scope=day&type=status&meigu=0', {
                        credentials: 'include',
                        headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
                    });
                    const text = await r.text();
                    let json = null; try { json = JSON.parse(text); } catch (e) {}
                    if (!json)       return 'no:non-json(http ' + r.status + ')';
                    if (json.error_code && json.error_code != 0)
                                     return 'no:error_code=' + json.error_code;
                    return 'yes:http ' + r.status;
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
                if result.error == nil { result.error = "session probe \(verdict ?? "nil")" }
            }
            log.info("[XueqiuProbe] session probe → \(verdict ?? "nil", privacy: .public)")
        } catch {
            let detail = Self.errorDetail(error)
            log.error("[XueqiuProbe] session probe failed: \(detail, privacy: .public)")
            if result.error == nil { result.error = "session probe: \(detail)" }
        }

        // 3) Stock-specific data fetch — proves end-to-end retrieval of THIS
        //    stock's data through the BYO session. Same-origin JSON API again:
        //    the stock's hot discussion users (`stock_hot_user.json`), keyed by
        //    the 雪球 symbol. A non-empty, non-error body confirms the cookie
        //    reaches a symbol-keyed endpoint. The production scraper later picks
        //    the richest sentiment endpoint (post timeline / search); the probe
        //    just needs to prove the path works. JS self-reports errors.
        do {
            let obj = try await page.callJavaScript("""
                try {
                    const r = await fetch('/recommend/user/stock_hot_user.json?symbol=' + encodeURIComponent(sym) + '&start=0&count=10', {
                        credentials: 'include',
                        headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
                    });
                    const text = await r.text();
                    return { status: r.status, len: text.length, sample: text.slice(0, 600) };
                } catch (e) {
                    return { error: ((e && e.message) ? e.message : String(e)) };
                }
            """, arguments: ["sym": symbol]) as? [String: Any]

            if let jsErr = obj?["error"] as? String {
                if result.error == nil { result.error = "data fetch JSERR: \(jsErr)" }
            } else {
                let sample = (obj?["sample"] as? String) ?? ""
                let len = (obj?["len"] as? Int) ?? sample.count
                let status = (obj?["status"] as? Int) ?? -1
                result.textLength = len
                result.textSample = sample
                log.info("[XueqiuProbe] data fetch http \(status, privacy: .public), \(len) chars")
            }
        } catch {
            let detail = Self.errorDetail(error)
            log.error("[XueqiuProbe] data fetch failed: \(detail, privacy: .public)")
            if result.error == nil { result.error = "data fetch: \(detail)" }
        }

        return result
    }

    /// Pull the underlying JS exception message (+ line) out of a thrown
    /// WebKit error so the opaque "A JavaScript exception occurred" becomes
    /// actionable. Falls back to `localizedDescription`.
    private static func errorDetail(_ error: Error) -> String {
        let ns = error as NSError
        if let msg = ns.userInfo["WKJavaScriptExceptionMessage"] as? String, !msg.isEmpty {
            let line = ns.userInfo["WKJavaScriptExceptionLineNumber"] as? Int
            return "JS: \(msg)" + (line.map { " (line \($0))" } ?? "")
        }
        return error.localizedDescription
    }

    // MARK: - Navigation awaiting

    /// Outcome of awaiting a single navigation.
    private enum NavOutcome: CustomStringConvertible {
        case finished
        case failed(String)
        case timedOut(Duration)

        var description: String {
            switch self {
            case .finished:            return "finished"
            case .failed(let m):       return "failed: \(m)"
            case .timedOut(let d):     return "timed out after \(d)"
            }
        }
    }

    /// Drive the navigation-event sequence returned by `WebPage.load(_:)` until
    /// `.finished`, racing a timeout so a hung headless load still returns a
    /// verdict rather than blocking forever. This is the deterministic idiom for
    /// headless awaits (the research doc's `isLoading` alternative is view-driven
    /// and not reliable off-screen).
    ///
    /// Generic over the opaque sequence type `load(_:)` hands back. Everything
    /// stays on `@MainActor` (the class is main-actor-isolated), so the sequence
    /// never crosses an isolation boundary and we sidestep `Sendable` friction.
    /// A sibling cancellation task enforces the timeout by cancelling the
    /// iterating task, whose `for try await` then throws `CancellationError`.
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
                // Stream ended without `.finished` (e.g. cancelled) — report it.
                return Task.isCancelled
                    ? .timedOut(timeout)
                    : .failed("navigation stream ended without finishing")
            } catch is CancellationError {
                return .timedOut(timeout)
            } catch {
                // `WebPage.NavigationError` (or any iterator error) lands here.
                return .failed(error.localizedDescription)
            }
        }

        // Timeout watchdog: cancel the iteration if it overruns.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            iterate.cancel()
        }

        let outcome = await iterate.value
        watchdog.cancel()
        return outcome
    }
}
