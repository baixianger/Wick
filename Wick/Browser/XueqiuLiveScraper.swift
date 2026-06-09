import Foundation
import WebKit
import TradingFloor
import os

/// The actual WebKit work behind the `BrowserSessionManager`, split out so the
/// manager itself stays testable: the manager talks to this small seam, and
/// unit tests inject a mock instead of driving real WebKit.
///
/// Everything here REUSES the compiler-verified `WebPage` API patterns from the
/// prototype (`Wick/Prototypes/Xueqiu/XueqiuProbe.swift`, committed `7283a5f`):
///   • `WKWebsiteDataStore(forIdentifier:)` with a FIXED persistent UUID,
///   • `WebPage.Configuration().websiteDataStore`,
///   • `page.load(_:)` RETURNS a `some AsyncSequence<NavigationEvent, Error>`
///     iterated with `for try await` (no `currentNavigationEvent`, no
///     `NavigationID`); failures are THROWN as `WebPage.NavigationError`, so we
///     race a timeout watchdog,
///   • `callJavaScript(_:arguments:in:contentWorld:)` → optional `Any`.
@available(macOS 26.0, *)
@MainActor
protocol XueqiuLiveScraping: Sendable {
    /// Build the visible login page bound to the named persistent store and
    /// kick off a load of the 雪球 origin. Returned page backs `WebView(page)`.
    func makeLoginPage() -> WebPage
    /// Cheap logged-in probe on a freshly-loaded headless page on the SAME
    /// store: `.valid` if a logged-in DOM marker is found, `.expired` on a
    /// login wall, `.unknown` if ambiguous / the probe couldn't settle.
    func probeStatus(timeout: Duration) async -> XueqiuSessionStatus
    /// Headless discussion extract on the same store. Best-effort: `[]` on
    /// no-session / empty / timeout / error; never throws.
    func extractDiscussion(symbol: String, timeout: Duration) async -> [String]
}

/// Live, WebKit-backed implementation. Owns NO long-lived state except the
/// store identifier; each headless extract spins a fresh `WebPage` on the same
/// named store (exercising the cross-instance cookie path, prototype linchpin A).
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

    static let loginURL = URL(string: "https://xueqiu.com")!

    private let log = Logger(subsystem: "me.impai.wick", category: "XueqiuLiveScraper")

    // MARK: - Store / pages

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

    /// Map a canonical CN/HK symbol (`600519.SS` / `0700.HK`) to the 雪球 path
    /// form (`SH600519` / `00700`). Centralised + clearly marked: the path/host
    /// shape is stable, but DOM selectors below are placeholders pending the
    /// live DOM.
    static func xueqiuSymbol(forCanonical canonical: String) -> String? {
        guard let market = CNSymbol.market(canonical) else { return nil }
        let code = canonical.split(separator: ".").first.map(String.init) ?? ""
        guard !code.isEmpty else { return nil }
        switch market {
        case .shanghai: return "SH\(code)"
        case .shenzhen: return "SZ\(code)"
        case .hongKong: return code   // 雪球 HK uses the bare code, e.g. /S/00700
        }
    }

    // MARK: - Status probe

    func probeStatus(timeout: Duration) async -> XueqiuSessionStatus {
        var config = WebPage.Configuration()
        config.websiteDataStore = makeStore()
        let page = WebPage(configuration: config)

        let events = page.load(URLRequest(url: Self.loginURL))
        let settled = await Self.awaitFinished(events, timeout: timeout)
        guard settled else { return .unknown }

        do {
            // Same logged-in heuristic as the prototype's linchpin-A probe.
            let value = try await page.callJavaScript("""
                const loggedInSel = ['.nav__user', '.user__name', 'a[href*="/u/"] img', '.avatar'];
                const loginWallSel = ['.login', 'a[href*="login"]', '.nav__login'];
                const has = sels => sels.some(s => document.querySelector(s) != null);
                const bodyText = (document.body && document.body.innerText) || "";
                const looksLoggedIn = has(loggedInSel);
                const looksWalled = has(loginWallSel) || (bodyText.includes("登录") && !looksLoggedIn);
                if (looksLoggedIn) return true;
                if (looksWalled)   return false;
                return null;
            """) as? Bool
            switch value {
            case .some(true):  return .valid
            case .some(false): return .expired
            case .none:        return .unknown
            }
        } catch {
            log.error("[Xueqiu] status probe failed: \(error.localizedDescription, privacy: .public)")
            return .unknown
        }
    }

    // MARK: - Discussion extract

    func extractDiscussion(symbol: String, timeout: Duration) async -> [String] {
        guard let xq = Self.xueqiuSymbol(forCanonical: symbol),
              let url = URL(string: "https://xueqiu.com/S/\(xq)") else { return [] }

        var config = WebPage.Configuration()
        config.websiteDataStore = makeStore()
        let page = WebPage(configuration: config)

        let events = page.load(URLRequest(url: url))
        let settled = await Self.awaitFinished(events, timeout: timeout)
        guard settled else { return [] }

        do {
            // PLACEHOLDER SELECTORS — finalise against the live 雪球 DOM. Kept
            // centralised here + clearly marked (same set the prototype used).
            let texts = try await page.callJavaScript("""
                const sel = [
                    '.timeline__item__content',
                    '.status-content',
                    '.timeline__item .content',
                    'article'
                ].join(',');
                const nodes = document.querySelectorAll(sel);
                return [...nodes]
                    .slice(0, limit)
                    .map(n => (n.innerText || "").trim())
                    .filter(t => t.length > 0);
            """, arguments: ["limit": 30]) as? [String]
            return texts ?? []
        } catch {
            log.error("[Xueqiu] discussion extract failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Navigation await (prototype idiom)

    /// Drive the navigation-event sequence to `.finished`, racing a timeout so a
    /// hung headless load still returns. Verbatim shape from the prototype's
    /// `awaitNavigation`, collapsed to a Bool (we only need settle/!settle here).
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
