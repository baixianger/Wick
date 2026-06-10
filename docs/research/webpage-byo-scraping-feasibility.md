# Feasibility: BYO-credential webpage scraping via SwiftUI WebKit (`WebPage`)

_Research deliverable — Wick (macOS 26 / SwiftUI), 2026-06-09._

> ✅ **LIVE-VALIDATED, in-WebKit JSON-API path (probe `8a73738`).** The production
> 雪球 path does **not** DOM-scrape and does **not** extract cookies into a
> `URLSession`. It operates **inside our own embedded WebKit**: ONE persistent
> headless `WebPage` on a named `WKWebsiteDataStore` (same UUID as the visible
> login `WebView`), loaded ONCE at the LIGHT root `https://xueqiu.com/`, against
> which every query is a same-origin `await fetch('/api/…')` driven by
> `callJavaScript` — the inherited login cookie auto-attaches
> (`credentials:'include'`). This is the equivalent of how snowball-cli drives
> Chrome over CDP (`callJavaScript` = `Runtime.evaluate`). The probe proved
> cross-store cookie visibility + same-origin authenticated `fetch`; the
> production scraper (`Wick/Browser/XueqiuLiveScraper.swift`) reuses exactly that.
> See §8 / §9 for the concrete endpoint + the -999 fix.

## TL;DR / Recommendation

**Yes — this is feasible and a good fit for Wick**, with caveats. Apple's WWDC25 SwiftUI WebKit API gives us exactly the primitive we need: a `WebPage` is an `@Observable` class that **runs headless with no view attached**, and the *same* instance can be dropped into a `WebView(webPage)` to become a visible in-app browser. One code path, two presentations. **The validated production technique is not DOM scraping but in-WebKit same-origin `fetch`:** we drive `callJavaScript(await fetch('/api/…'))` against 雪球's JSON API from inside a logged-in headless page, all on-device, with no backend. (DOM extraction and the cookie-extract + `URLSession` alternative were both **dropped** in favour of staying in-WebKit — see §8/§9.)

The defensible model is: **the user signs in ONCE in a visible in-app `WebView`; the cookie/session is persisted in an app-isolated `WKWebsiteDataStore`; later, user-triggered headless `WebPage` calls reuse that session to read the user's OWN data** — their X/Reddit/雪球 timeline, or their own broker holdings — and hand clean text to the app's analysts. No password storage, no OAuth, no shared/pooled credentials.

A `BrowserSessionManager` in the app target supports **three operating modes** (formalized in §3): **(1)** persistent authenticated sessions per site (雪球 / Twitter-X — login once, drive headless later); **(2)** session-expiry detection + a re-login prompt, with a per-site `valid ✓ / expiring ⚠ / expired ✗` status; and **(3)** a no-auth "browser as transport" fallback that fetches block-prone JSON/HTML endpoints (e.g. EastMoney) through a real browser context when raw `URLSession` is refused.

Recommendation:
1. Build this as an **app-target-only `BrowserSessionManager`** vending `WebScrapeProvider` / `WebSessionProvider` (Modes 1–2) plus a `BrowserHTTPTransport` (Mode 3), conforming to the existing `SocialSentimentProvider` seam in the `TradingFloor` package (the package stays Foundation-only / Linux-clean — `WebPage` is Apple-platform only).
2. Keep the project's existing guardrails (`requiresUserCredentials = true`, `interactiveOnly = true`) and extend them to the broker case.
3. Prototype against **雪球 (Xueqiu)** first — it's the lowest-risk, highest-value target and we already ship a Xueqiu data skill. **A runnable dev probe already exists** (commit `7283a5f`, behind a `#if DEBUG` Developer menu) covering the two linchpins — same-store cookie cross-visibility and headless SPA render — and only awaits a manual login to validate (selectors pending live-DOM).
4. Treat each site/broker as a **separate, brittle page-structure adapter**; expect maintenance. Surface the visible `WebView` for captcha/2FA/login (human-in-the-loop). Never run in background/batch.

The honest risks are *durability and ToS*, not technical capability: DOM adapters break when sites redesign, anti-bot (Cloudflare) can challenge headless loads, and the legal posture only holds because it's the user reading their own data with their own session on their own device.

One nuance worth stating up front (full treatment in §6.1): because `WebPage` is the **genuine Safari WebKit engine** running the user's **genuine logged-in session**, it defeats the fingerprint-detection layer (`navigator.webdriver`, CDP signatures, fake fingerprints) that catches Playwright/Selenium-class scrapers — so it is a materially *better* client for hard targets than conventional headless tooling. The residual risk on X/Twitter is **behavioral** (Error 226) and **telemetry** (per-request transaction-id), not fingerprinting; that keeps X a best-effort, strongly-throttled source while 雪球 / EastMoney remain the dependable value.

---

## 1. The new API — `WebPage` (headless) vs `WebView(webPage)` (rendered)

Source: WWDC25 Session 231, "Meet WebKit for SwiftUI" (<https://developer.apple.com/videos/play/wwdc2025/231/>); Apple docs `WebPage` (<https://developer.apple.com/documentation/webkit/webpage>).

> ✅ **Compiler-verified against the prototype (commit `7283a5f`).** The API facts below were originally research; they are now checked against a built 雪球 probe (`Wick/Prototypes/Xueqiu/XueqiuProbe.swift` et al.). Several earlier idioms turned out to be wrong and are corrected in place; the corrected forms compile.

`WebPage` is a **brand-new `@Observable` class** that represents web content and is usable **on its own, with no view attached** — i.e. as a headless browser. To *display* it, you hand the same instance to the new `WebView`:

```swift
WebView(webPage)   // renders the page; omit it entirely to stay headless
```

This is the key architectural property for us: **`WebPage` alone = headless browser; `WebPage` inside a `WebView` = in-app browser; one code path, two presentations.**

### Availability gating

```swift
@available(iOS 26.0, macOS 26.0, *)
```

`WebPage` / `WebView` are new in the 26 SDKs (macOS/iOS/iPadOS/visionOS/watchOS now share version 26). Wick targets macOS 26, so this is in-window; guard any shared-target code with `if #available(macOS 26.0, *)`.

### Loading a URL

```swift
let page = WebPage()                 // or WebPage(configuration:)
let events = page.load(URLRequest(url: url))   // RETURNS the navigation-event stream directly
// also: load(html:baseURL:), load(_:mimeType:characterEncoding:baseURL:)
```

### Observing navigation / load completion

`WebPage` exposes observable properties: `isLoading`, `estimatedProgress`, `title`, `url`. Two idioms:

**a) SwiftUI `onChange` on `isLoading`** (simple, view-driven):

```swift
.onChange(of: webPage.isLoading) { wasLoading, isLoading in
    guard wasLoading, !isLoading else { return }
    // finished loading
}
```

**b) Iterate the navigation-event stream `load` returns** (correct for headless await; recommended).

> ⚠️ **Corrected (verified `7283a5f`).** The earlier idiom — `Observations { page.currentNavigationEvent }` matched against a `NavigationID` — **does not exist**. There is **no** `currentNavigationEvent` property and **no** `NavigationID` type. Instead, `load(_:)` itself **returns** the navigation-event stream: `load(_ request:) -> some AsyncSequence<NavigationEvent, Error>`. You iterate it (or the `WebPage.navigations` property) with `for try await`.

`NavigationEvent` has **only 4 cases** — `.startedProvisionalNavigation`, `.receivedServerRedirect`, `.committed`, `.finished`. There is **no** `.failed` / `.failedProvisionalNavigation` case and **no** `.kind`. Failures are **thrown** from the throwing sequence as `WebPage.NavigationError`. So "await finished" is a `for try await` loop wrapped in a timeout watchdog:

```swift
let events = page.load(URLRequest(url: url))   // some AsyncSequence<NavigationEvent, Error>
for try await event in events {                // a thrown WebPage.NavigationError = the failure path
    if case .finished = event { break }
}
```

(Sources: <https://troz.net/post/2025/swiftui-webview/>, <https://danielsaidi.com/blog/2025/06/10/webview-is-finally-coming-to-swiftui>; corrected against the prototype.)

### `callJavaScript(...)` — drive the DOM

Signature: `callJavaScript(_:arguments:in:contentWorld:)` (<https://developer.apple.com/documentation/webkit/webpage/calljavascript(_:arguments:in:contentworld:)>). It is the `WebPage` analogue of `WKWebView.callAsyncJavaScript`. Verified semantics:

- The string is an **async JavaScript function body** — you write `return ...` to produce a value.
- `arguments: [String: Any]` — **dictionary keys become local variables** inside the JS body (so you pass data from Swift without string-interpolating it). Values are bridged to JS types.
- It is `async throws` and **returns an optional `Any`** which you cast to the expected Swift type.
- If the JS returns a Promise, the call awaits it.

```swift
// read the fully-rendered DOM
let html = try await page.callJavaScript(
    "return document.documentElement.outerHTML.toString();"
) as? String

// pass arguments — keys become JS locals
let result = try await page.callJavaScript(
    "return document.querySelector(sel)?.innerText ?? null;",
    arguments: ["sel": ".some-class"]
) as? String
```

Reading `document.documentElement.outerHTML` after `finished` gives us the **rendered** HTML (post-JS, post-login), which is exactly what raw `URLSession` fetching cannot get for SPA-heavy sites like X or 雪球. (Sources: WWDC25-231; <https://folding-sky.com/blog/ios-26-macos-26-swiftui-headless-browser-webpage-webview>; `callAsyncJavaScript` arguments semantics confirmed at <https://developer.apple.com/documentation/webkit/wkwebview/callasyncjavascript(_:arguments:in:contentworld:)>.)

> The "Replacing Server-Side AI Search with iOS 26's New Headless Browser" writeup demonstrates exactly this pattern (headless `WebPage` + `callJavaScript` + `outerHTML`) to replace a server-side scraper — strong external validation of our use case.

### Verified unchanged (`7283a5f`)

These earlier facts held against the prototype, no correction needed:

- `WKWebsiteDataStore(forIdentifier:)` with a **fixed persistent UUID**, recreated on relaunch to restore the session.
- `WebPage.Configuration().websiteDataStore` carries that store into the page.
- `callJavaScript(_:arguments:in:contentWorld:)` — dictionary keys → JS locals; returns an optional `Any`.
- `WebView(webPage)` to render the same instance; `#available(macOS 26.0, *)` gating.

### `@Observable` controller caveat (`7283a5f`)

An `@Observable` controller **cannot** hold the login `WebPage` as a `lazy var` — the Observation macro fails to compile (`"init accessors can refer only to stored properties"`). Make it `@ObservationIgnored` and construct it in `init` via a static factory:

```swift
@Observable
final class LoginController {
    @ObservationIgnored let page: WebPage   // NOT `lazy var`
    init(storeID: UUID) { self.page = Self.makePage(storeID: storeID) }
    private static func makePage(storeID: UUID) -> WebPage { /* … */ }
}
```

---

## 2. Cookie / session persistence (sign in once, reuse headless)

Sources: `WKWebsiteDataStore` (<https://developer.apple.com/documentation/webkit/wkwebsitedatastore>); "Building Profiles with new WebKit API" (<https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/>); `WebPage.Configuration`.

`WebPage.Configuration` carries a `websiteDataStore`, "the object used to get and set the site's cookies and to track cached data objects." Key facts:

- **`WKWebsiteDataStore.default()`** = persistent. Cookies, `localStorage`, `sessionStorage` survive app relaunch.
- **`.nonPersistent()`** = incognito; cleared on termination.
- **Isolated from Safari.** App `WKWebView`/`WebPage` data does *not* sync with Safari and vice versa — this is per-app sandboxed storage, not the system cookie jar.
- **Multiple named persistent stores** via `WKWebsiteDataStore(forIdentifier:)` (macOS 14 / iOS 17+). You keep the `UUID` identifier, and on relaunch recreate the store with the same identifier to restore the session. `fetchAllDataStoreIdentifiers` lists existing ones. This lets us give each site/broker its **own isolated, named, persistent session** (so 雪球 cookies never mix with the broker's).

**The flow this enables:**

1. User taps "Connect 雪球 / Connect broker" → Wick shows a **visible `WebView`** backed by a named persistent data store, pointed at the site's login page.
2. User logs in **themselves** (password, SMS 2FA, captcha — all handled by the human in the visible view). Wick stores **nothing** — no password, no token. The cookie lives only in WebKit's app-isolated store.
3. Later, a **user-triggered** action constructs a **headless** `WebPage(configuration:)` using the *same* named data store; the persisted cookie authenticates the request; Wick reads the DOM.

No OAuth, no Keychain secret, no credential pooling. The session is bound to the device and the app sandbox.

```swift
@available(macOS 26.0, *)
func makePage(forSiteIdentifier id: UUID, visible: Bool) -> WebPage {
    var config = WebPage.Configuration()
    config.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)  // persistent, named, isolated
    return WebPage(configuration: config)
    // hand to WebView(page) when `visible` (login / captcha); keep headless otherwise
}
```

---

## 3. The three browser-session operating modes

§2 establishes the underlying mechanism (sign-in-once + named persistent store + reuse headless). In practice the app needs that mechanism in three distinct shapes. A single app-target **`BrowserSessionManager`** must support all three; everything downstream (the social providers of §4, the broker provider of §5, and the EastMoney/Yahoo data chains) is built on one of them. The three modes share one `WebPage`/`WKWebsiteDataStore` substrate but differ in whether a login store is involved and in how failure is detected and surfaced.

### Mode 1 — Persistent authenticated session (雪球 / Twitter-X)

The default for any source that requires the user's own login. **One named persistent `WKWebsiteDataStore(forIdentifier:)` per site** — separate, isolated cookie jars that persist across app launches (雪球 and Twitter-X each get their own `UUID`; their cookies never mix). The flow is exactly §2's: the user logs in **once** in a visible `WebView` bound to that site's store; WebKit writes the auth cookie into the store; later the agent constructs a **headless** `WebPage` bound to the **same store identifier** and drives `callJavaScript` (§1) to search/fetch, transparently reusing the cookie. **No password storage, no OAuth, no token capture** — only the user, in a real browser view, ever sees the credential.

**Privacy/security invariant (load-bearing):** the cookies live in the OS-managed, app-sandboxed `WKWebsiteDataStore` and **stay there**. Wick must **never** extract, serialize, copy, or transmit them — not to our own files, not to the Keychain-as-export, and never to any server. The app holds only the *store identifier* (a `UUID`), not the secret. This is what makes Mode 1 uphold the BYO privacy posture (§6): the session is bound to the device and the sandbox, and Wick's code is structurally incapable of exfiltrating it because it never reads the cookie value at all.

### Mode 2 — Session-expiry detection + re-login prompt

A persisted cookie eventually expires or is invalidated server-side. Mode 2 detects that **before and during** a scrape, and never scrapes with a stale session. Two complementary mechanisms — **both required**:

- **Proactive probe (before a scrape).** A cheap `callJavaScript` check on a freshly-loaded page for a *logged-in-only DOM marker* (e.g. the avatar/account menu) — and conversely, presence of a **login form ⇒ logged out**. Optionally cross-check whether the known auth cookie still exists / hasn't expired in the data store. Fast, runs before committing to the real fetch.
- **Reactive capture (during a scrape).** Watch the navigation events (§1, the stream `load` returns — `.receivedServerRedirect` / `.committed`): if navigation **redirects to the site's login URL**, or the returned DOM is the **logged-out shell**, mark the session **stale** mid-flight and abort the extraction.

**Per-site session-status model** — a small state machine surfaced in the UI:

| Status | Meaning | Effect |
|---|---|---|
| `valid ✓` | logged-in marker present, cookie unexpired | scrapes run |
| `expiring ⚠` | cookie near its expiry window | scrapes still run; nudge the user to re-login soon |
| `expired ✗` | login wall detected, or cookie gone | **source auto-pauses**; never scrape |

Surface this as a per-source row, e.g. **"雪球 ✓ 已登录 · 推特 ✗ 需重新登录"**. Tapping an `expired ✗` source **re-opens the visible `WebView`** (same `WebPage`/store identifier) so the user can re-login in place; on success the status flips back to `valid ✓` and the source un-pauses. While `expired ✗`, that source is auto-paused and contributes nothing to any run — the "never scrape with a stale session" guarantee.

### Mode 3 — No-auth "browser as transport" (API-accessibility guarantor)

Distinct from Modes 1–2: **no login, no per-site store** — just a real browser context used to reach endpoints that reject plain HTTP. Some JSON/HTML endpoints refuse raw `URLSession`/curl traffic. **Real, observed in this project:** while probing data feeds, EastMoney's `push2his.eastmoney.com` **IP-temp-blocked a burst of raw-HTTP requests**, returning empty responses to every client behind that IP. A shared headless `WebPage` (no login store needed) fetches such endpoints **through a genuine browser** — real User-Agent, real TLS fingerprint, JS execution, normal cookie handling — so the server treats it as an ordinary browser session rather than a scraper.

**Position it as a FALLBACK TRANSPORT, not the default.** A headless `WebPage` is heavier than `URLSession` (full WebKit load), so providers must **try lightweight HTTP first** and only **degrade to the browser transport on a block / empty-response signal**. This benefits the **EastMoney** and **Yahoo** provider chains specifically. It complements — does not replace — the project's existing mitigations: **per-day caching** and the **`HTTPRateLimiter`** stay the first line of defence (they reduce how often we hit the endpoint at all); Mode 3 is the recovery path *when an endpoint blocks us anyway*. A single shared `WebPage` (no named store) is sufficient for the whole app — Mode 3 has no per-site session state.

```swift
// Mode 3, sketch: lightweight HTTP first, browser transport only on block.
func fetch(_ url: URL) async throws -> Data {
    if let data = try? await http.get(url), !data.isEmpty { return data }   // URLSession + HTTPRateLimiter + per-day cache
    return try await browserTransport.fetch(url)                            // shared headless WebPage fallback
}
```

---

## 4. Use case A — BYO-cookie social sentiment (X / Reddit / 雪球)

**Goal:** the user logs into X / Reddit / 雪球 once; later Wick uses a headless `WebPage` + `callJavaScript` to read the user's timeline, a stock's hot posts, or a discussion thread, converts the DOM to clean text/markdown, and feeds it to the app's sentiment analyst (`SocialSentimentProvider` in the package).

**Why DOM, not API:** Reddit's free API is non-commercial and rate-limited; X has **no free tier**. Both are SPAs whose content only exists after JS render and login — `URLSession` HTML fetch returns an empty shell. A logged-in headless `WebPage` sees the real, rendered timeline.

**DOM → clean text (token reduction):** don't ship raw `outerHTML` to the LLM. Run extraction JS that returns only post text + author + timestamp as a compact array, then format to markdown. This cuts tokens by ~10-50× vs raw HTML and removes tracking/script noise.

```swift
let posts = try await page.callJavaScript("""
    const nodes = document.querySelectorAll(postSelector);
    return [...nodes].slice(0, limit).map(n => ({
        author: n.querySelector(authorSel)?.innerText ?? "",
        text:   n.querySelector(textSel)?.innerText ?? "",
        time:   n.querySelector('time')?.getAttribute('datetime') ?? ""
    }));
    """,
    arguments: ["postSelector": cfg.postSelector,
                "authorSel":    cfg.authorSelector,
                "textSel":      cfg.textSelector,
                "limit":        30]
) as? [[String: Any]]
```

Map the result into the package's existing `SocialPost` (`source`, `text`, `score?`, `createdAt?`) and `SocialSentiment` types, with `source` = `"X (BYO)"` / `"雪球 (BYO)"`. The provider sets `requiresUserCredentials = true` and `interactiveOnly = true`, so the existing `SocialSentimentTool.usable` filter automatically excludes it from any non-interactive / batch run.

**Keep raw posts ephemeral.** Extract → summarize → discard. Don't persist scraped post bodies (ToS + privacy posture, see §6).

---

## 5. Use case B — broker holdings / trade history

**Goal:** user logs into their broker's web portal once; Wick reads the holdings table + trade-history table straight from the DOM and normalizes into the app's existing `HoldingsStore` (`Wick/Data/Holdings.swift`, which already models `Holding`, `HoldingSide`, and a `HoldingSource` with an `.imported(broker:document:)` case — a natural slot for a new `.webPortal(broker:)` source).

```swift
let rows = try await page.callJavaScript("""
    const tr = document.querySelectorAll(rowSel);
    return [...tr].map(r => {
        const c = r.querySelectorAll('td');
        return { symbol: c[0]?.innerText.trim(),
                 qty:    c[1]?.innerText.trim(),
                 cost:   c[2]?.innerText.trim(),
                 mktVal: c[3]?.innerText.trim() };
    });
    """,
    arguments: ["rowSel": brokerCfg.holdingsRowSelector]
) as? [[String: Any]]
```

### DOM extraction vs screenshot/image OCR

| | DOM extraction (`callJavaScript`) | Screenshot + OCR |
|---|---|---|
| Structure | **Structured** — cell-by-cell, typed | Flat pixels; must re-segment rows/columns |
| Fidelity | **Lossless** — exact strings/numbers | Lossy — OCR misreads `0/O`, `,`/`.`, minus signs |
| Repeatability | **Deterministic** for a given layout | Varies with rendering, zoom, theme, fonts |
| Cost | Cheap, instant, no model call | Vision-model tokens + latency per refresh |
| Pagination | Can scroll/click and re-query in JS | Re-screenshot every page |

**DOM extraction is strictly better wherever the data lives in real HTML elements.** It's structured, repeatable, and lossless.

**Where OCR still helps:** brokers that render holdings into a `<canvas>` or `<svg>`, into background images, or behind deliberate anti-scrape obfuscation (CSS-shuffled columns, pseudo-element digits, custom-font glyph remapping). There the DOM has no readable text, so fall back to `WebView` snapshot → Vision/OCR. Treat OCR as the **fallback adapter**, DOM as the **primary**.

Normalize either way through the same `Holding` mapping (symbol resolution via the package's `CNSymbol` / `MarketRouter`, currency, qty, cost).

---

## 6. Constraints & posture

- **User-triggered only.** Every scrape is behind an explicit action — e.g. a "刷新持仓" (refresh holdings) button or a "pull sentiment" tap. **No background, scheduled, or batch scraping.** Wire this through the existing `interactive` flag on `SocialSentimentTool` and an equivalent guard for the broker provider.
- **Captcha / 2FA / login → human-in-the-loop.** When a headless call hits a login wall, captcha, or challenge (detect via redirect to a login URL, or a sentinel selector), **surface the visible `WebView`** (same `WebPage` instance) and ask the user to resolve it. Then resume headless. This is the single biggest reliability win of the "one page, two presentations" model.
- **One adapter per site/broker.** Selectors and flows are site-specific and **brittle**; isolate each as its own `SiteScrapeAdapter` with versioned selectors so a redesign breaks (and is fixed) in one place.
- **Anti-bot reality.** Some sites (Cloudflare "checking your browser", bot fingerprinting, rate limits) may challenge even a logged-in headless `WebPage`. Mitigations: reuse the real persisted session (already logged in helps a lot), keep volume low and human-paced, and fall back to the visible `WebView` on challenge. Do not attempt fingerprint evasion — that crosses the line from "user reads their own data" to circumvention.
- **Twitter/X is the hard case.** X **aggressively detects automation even when logged in** — expect intermittent breakage of a Mode-1 headless drive against it. Keep the X source **strictly user-triggered, off by default, and ephemeral**; treat any given fetch as best-effort and surface failure rather than retrying hard. **雪球 is far friendlier** to a logged-in headless session, and — combined with Mode 3's browser transport for its data endpoints — it is the **most robust first target**. Prototype on 雪球; treat X as a later, lower-reliability tier. The detection picture is analysed in detail in §6.1.

### 6.1 X / Twitter automation-detection analysis

X warrants its own analysis because it is the single hardest target and because the new `WebPage` engine changes the calculus in a way that is easy to over- or under-state.

**Key insight — using Apple's real WebKit changes the detection picture.** Most "anti-headless" detection in the wild — Cloudflare Bot Management, DataDome, FingerprintJS BotD — is tuned to catch **automation frameworks** (Selenium / Playwright / Puppeteer), via tells like the `navigator.webdriver` flag, Chrome DevTools Protocol (CDP) signatures, a `HeadlessChrome` user-agent, missing plugins, and anomalous Canvas/WebGL/AudioContext/font fingerprints ([Latenode: how headless detection works](https://latenode.com/blog/web-automation-scraping/avoiding-bot-detection/how-headless-browser-detection-works-and-how-to-bypass-it), [FingerprintJS BotD](https://dev.fingerprint.com/docs/bot-detection-vs-botd), [ZenRows: bypassing Cloudflare](https://www.zenrows.com/blog/bypass-cloudflare)). Apple's `WebPage` exhibits **none** of these: it is the genuine Safari WebKit engine with a real UA, real canvas/font fingerprints, and a real Safari-like TLS fingerprint (JA3/JA4) because it goes through Apple's network stack. So this entire class of "is this an automation tool?" detection is **largely defeated by construction** — a real advantage over Playwright-class tooling, and the core reason `WebPage` is a materially better X client than any framework-driven headless browser.

**Caveats — what X still catches, independent of the engine.** The fingerprint layer is not the only layer:

1. **Behavioral detection (Error 226) is the main residual risk.** X's "This request looks like it might be automated" is a **behavioral** verdict — HTTP `403` carrying in-body code **226** — triggered by actions that are too fast / too regular, lacking human-interaction entropy, or following scripted navigation patterns. It fires **even when the request is correctly authenticated and within rate limits**, which makes it distinct from rate-limiting (HTTP `429` / body code `88`). Sources: [X dev community thread on 226](https://devcommunity.x.com/t/error-code-226-this-request-looks-like-it-might-be-automated/12872), [Sorsa analysis](https://api.sorsa.io/blog/twitter-this-request-looks-like-automated). No engine choice defeats this; only human-paced behaviour does.
2. **The `x-client-transaction-id` request header.** X's web front-end generates this **per-request** via on-page JavaScript for its internal GraphQL calls. Calling X's internal API directly from `callJavaScript` would mean reproducing that header — a fragile cat-and-mouse (cf. the open-source [XClientTransactionJS](https://github.com/swyxio/XClientTransactionJS) generator that has to track X's changes). The clean way that **sidesteps** this entirely: don't call internal APIs at all — drive the actual rendered web app, let X's own JS produce the transaction-id naturally, and read the resulting DOM.
3. **Account / IP reputation and interactive challenges.** Re-verification, captcha, and 2FA can interpose regardless of engine or behaviour — handled by the human-in-the-loop visible `WebView` (§6, captcha/2FA bullet).

**Design implications** (these refine Mode 1 of §3 for the X adapter specifically):

- **Read the rendered DOM, not X's internal API.** Let X's own machinery run — transaction-id, CSRF, everything correct — and only read what it renders. This is the §4 "DOM, not API" stance applied to X, and it is what neutralizes caveat #2.
- **For X, prefer a real rendered `WebView` over a fully headless `WebPage`** — even offscreen or minimized — so timing / `requestAnimationFrame` / visibility signals are genuine rather than absent. This directly connects to open question 1 (§9): whether a never-rendered headless `WebPage` behaves identically for SPA pages. For X we should assume it may **not**, and bias toward an attached (if hidden) view.
- **Strictly human-paced, user-triggered, low-volume, off by default, ephemeral.** This is the only real defence against caveat #1 (Error 226). Surface the visible `WebView` for challenges / captcha / 2FA (caveat #3).
- **Realism ordering.** X is the hardest target — treat it as **best-effort and behaviour-throttled**. 雪球 (Xueqiu) and EastMoney are far softer, so the robust value and the first prototype belong there (reinforcing §8 and the TL;DR: prototype on 雪球 first).

**Net conclusion.** `WebPage` materially beats Playwright-class tooling on X because it is the genuine engine *plus* the user's genuine logged-in session — together these defeat the **fingerprint-detection layer** that catches conventional scrapers. But X's **behavioral** (Error 226) and **telemetry** (transaction-id) layers remain, so X stays a **best-effort, strongly-throttled** source while the dependable value sits with 雪球 / EastMoney.

### ToS / legal posture (consistent with project memory)

Project rule (memory: _tradingfloor-data-sources_, and the in-code doc-comment on `SocialSentimentProvider`): X/Reddit are **BYO user-credential ONLY, opt-in, off by default, interactive-mode only, never server-side/batch; keep raw posts ephemeral; show a ToS notice** — because Reddit's free API is non-commercial and X has no free tier.

The defensible framing extends cleanly to the webpage layer:

> **The user reads their OWN data with their OWN logged-in session on their OWN device.**

This is materially different from pooled/shared scraping credentials run server-side, which violate commercial ToS. Because Wick is a **BYO-everything, no-backend** product (memory: _wick-business-model_), this `WebPage` layer makes the **local app more capable without Wick ever touching the user's data or credentials** — fully aligned with the business model. Still: show a clear ToS/consent notice on first connect, keep it opt-in and off by default, and keep scraped social content ephemeral.

---

## 7. Architecture placement

`WebPage` / `WebView` / `WKWebsiteDataStore` are **Apple-platform-only** (WebKit). They **must not** enter the `TradingFloor` SPM package, which is Foundation-only and Linux-clean (it's where market/sentiment *protocols* and Linux-safe adapters live).

**Seam:** keep the protocol in the package; put the WebKit implementation in the **Wick app target**.

At the centre of the app target sits the **`BrowserSessionManager`** — the single owner of all three operating modes (§3). Per site it owns the `WebPage`, the named `WKWebsiteDataStore`, the login/logout flow, and the Mode-2 session-status state machine (`valid ✓ / expiring ⚠ / expired ✗`). It exposes two distinct surfaces:

- **`WebScrapeProvider` / `WebSessionProvider`** → conform to the package's `SocialSentimentProvider` seam, driving **Mode 1 + Mode 2** for 雪球 / 推特 sentiment (and broker holdings via `HoldingsImportProvider`).
- **`BrowserHTTPTransport`** → the **Mode 3** fallback transport, injected into the EastMoney / Yahoo providers' fetch chains so they can degrade from `URLSession` to the shared headless `WebPage` on a block / empty response.

```
TradingFloor (package, Linux-clean)
└── SocialSentimentProvider  (protocol; requiresUserCredentials / interactiveOnly guards)  ← already exists
└── (new) HoldingsImportProvider (protocol, optional — mirror the same guard flags)
└── EastMoney / Yahoo providers — accept an injected transport (URLSession by default; no WebKit dep)

Wick (app target, macOS-only)
└── BrowserSessionManager  — OWNS per-site WebPage + named WKWebsiteDataStore + login flow + Mode-2 status state machine
    ├── WebSessionProvider     — vends headless/visible WebPage; Mode 1 login, Mode 2 expiry detection
    ├── WebScrapeProvider      — runs callJavaScript adapters; DOM→text/markdown
    └── BrowserHTTPTransport   — Mode 3: shared no-auth headless WebPage as fallback transport → EastMoney/Yahoo chains
└── XueqiuSentimentProvider : SocialSentimentProvider   (requiresUserCredentials = true, interactiveOnly = true)
└── BrokerHoldingsProvider : HoldingsImportProvider     (feeds Wick/Data/HoldingsStore)
└── SiteScrapeAdapter      — per-site selectors/flow (Xueqiu, X, Reddit, broker A, broker B…)
```

**All WebKit lives in the Wick app target only.** The `TradingFloor` SPM package stays Foundation-only / Linux-clean — it never imports WebKit. Its market/social providers accept an **injected transport** (defaulting to `URLSession`), so Mode 3's `BrowserHTTPTransport` is wired in from the app side without the package depending on it — the same dependency-inversion pattern as the BYO X/Reddit rule. The package keeps the **policy** (`requiresUserCredentials`, `interactiveOnly`, and the `interactiveOnly` guard reused for any browser-backed provider) so guards are enforced regardless of which concrete app-side provider is wired in. The app keeps the **WebKit mechanism**. This is consistent with how `WickMarketDataProvider` (app) wraps package providers today.

### 7.1 Browser presentation model

**Core principle: session and presentation are DECOUPLED.** The `WebPage` *is* the session (cookies in its `WKWebsiteDataStore`); the `WebView` is merely one *presentation* of it. One `WebPage`, swap the presentation freely — attach a `WebView`, detach it, attach a different one — and the session is never broken. This is what makes the states below cheap: they are presentation choices over a single long-lived session, not separate browsers.

There are **three user-facing states plus one implementation state**:

- **① Default headless** (agent scraping). No browser is shown at all. **Most agent browser ops show no browser.** The UI surfaces only a status indicator + an activity log in the main window so the user knows work is happening.
- **② Interaction required** (login / captcha / 2FA / Mode-2 re-login). A **separate, dismissible macOS window** (SwiftUI `Window(id:)` + `openWindow`). **Recommended** over an embedded panel or a full-window sheet: login is a focused, transient credential task; a separate window lets the user keep the analysis visible alongside it, scales naturally to multi-site (one titled window per site), and reinforces the "this is **YOUR** session" BYO framing.
- **③ Optional "watch the agent"** (transparency / debug). An **embedded, collapsible, read-only panel** (a side or bottom drawer) the user toggles on. Embedded is right here — unlike login, it's glanceable workflow context the user wants *beside* the analysis, not a separate task.
- **Implementation state — attached-but-hidden** (not a user-facing window). An offscreen-rendered `WebView` kept attached for **X realism** (genuine timing / `requestAnimationFrame` / visibility signals) — see §6.1.

**Interaction etiquette.** The agent **never steals focus mid-run.** When a headless op hits a wall it sets a `needs-interaction` state and the UI floats a gentle, **non-blocking** prompt ("雪球需要登录 →") that the user taps to open the interaction window (state ②). This is the UI manifestation of the Mode-2 per-site status row (§3) — an `expired ✗` source raises the prompt rather than interrupting whatever is on screen.

### 7.2 Session lifecycle — view-independent ownership

**Requirement (stated plainly):** leaving or closing the analysis view must **not** interrupt the browser operation. Mechanics, kept lightweight (this is an ownership point, not heavy blocking machinery):

- **Do not** run the scrape `Task` from a SwiftUI View's `.task {}` modifier or a View `@State` — those are cancelled / torn down when the view disappears.
- **Own the `WebPage` + scrape `Task` in the app-scoped `BrowserSessionManager`** — held at the App/Scene root, `@Environment`-injected, a peer of the existing `LiveDataStore` / `AgentRuntime`. A headless `WebPage` needs **no** `WebView` in the view hierarchy to keep running; it lives as long as the manager holds it. Leaving a view just detaches UI observation — the work continues. Progress is exposed via the manager's `@Observable` state and surfaced by a **global** indicator independent of which view is on screen.
- The **only** view-bound piece is the visible login `WebView` (state ②, its own window). The session itself — the cookie in `WKWebsiteDataStore` — persists independently of that window: closing it, or leaving the analysis view, does **not** kill the session.

> Because browser / BYO-cookie data is device-pinned and may need interaction, that part stays **on-device** and cannot move to the (deferred) server-compat phase — only the headless-HTTP + LLM parts could.

---

## 8. Production path — 雪球 (Xueqiu) BYO-cookie, in-WebKit JSON API (live-validated)

Lowest-risk first target: we already ship a Xueqiu data skill, the value is clear (CN retail sentiment), and 雪球's web app is backed by same-origin JSON endpoints that a logged-in page can `fetch` directly — **no DOM scraping needed**.

> ✅ **This section now describes the SHIPPED design, validated by probe `8a73738`** (`Wick/Prototypes/Xueqiu/XueqiuProbe.swift`), not a plan. DOM scraping was dropped because the JSON path is far more robust (no selector brittleness) and the cookie-extract + `URLSession` path was dropped because operating in-WebKit keeps the cookie inside the OS-managed store (the §6 privacy invariant) and reuses the genuine session/fingerprint.

**Step 1 — connect (visible, once).** Show `WebView(loginPage)` with a named persistent data store pointed at `https://xueqiu.com`. User logs in (and clears any captcha) themselves. WebKit writes the auth cookie into the store keyed by the fixed `storeID` UUID.

**Step 2 — ONE persistent headless page, loaded once at the LIGHT root.** `BrowserSessionManager` (via `XueqiuLiveScraper`) owns a single long-lived headless `WebPage` on the *same* named store, loaded ONCE at `https://xueqiu.com/` — **not** the heavy per-stock SPA. It is loaded lazily on first use and reused for the app's lifetime; it is only reloaded if missing/torn down.

**Step 3 — every query is a same-origin `fetch` on that already-loaded page.** No per-call navigation. The status probe is:

```js
await fetch('/statuses/hots.json?…', { credentials:'include',
    headers:{ 'Accept':'application/json','X-Requested-With':'XMLHttpRequest' } })
```

→ valid JSON without an `error_code` ⇒ session valid. The per-stock discussion feed is:

```
/statuses/search.json?q=<XQsymbol>&count=20&page=1&sort=time&source=all
```

(same-origin on `xueqiu.com`; snowball-cli's `searchPosts`). The response is `{ count, list: [ { description|text, user.screen_name, reply_count, like_count|fav_count, retweet_count, created_at, target } … ] }`. The raw body is handed to the package's pure `XueqiuPostParser` (HTML-strip + entity-decode the body, fall back `like_count → fav_count`), and each post is formatted to a self-tagged news line: `[雪球·<作者>] <text ~80 chars> (赞<n> 评<n>)`.

> ⚠️ **The -999 fix (load-bearing).** The probe was initially unstable with `NSURLErrorDomain -999` (cancelled) because it built a FRESH `WebPage` and NAVIGATED to the heavy stock SPA on **every** call — overlapping navigations cancel one another. The fix is the persistent-page design above: navigate ONCE to the light root, then never re-navigate; every query is a `fetch` on the settled page. First-use load tolerates a single -999 (superseded) and retries once; concurrent first-use callers coalesce onto one load task.

**Step 4 — analyze.** The formatted lines flow through the off-by-default `BYODiscussionNewsDecorator` into the snapshot's `news` for CN/HK tickers; the sentiment/news analysts read them. Discard raw post bodies after.

### Symbol mapping (centralised)

Canonical → 雪球 lives in the package's Foundation-only `CNSymbol.xueqiuSymbol` (unit-tested): `600519.SS → SH600519`, `000001.SZ → SZ000001`, `0700.HK → 00700` (5-digit). The app-side scraper just delegates to it.

### Swift sketch (illustrative, API-accurate)

```swift
import WebKit
import SwiftUI

@available(macOS 26.0, *)
@Observable
final class XueqiuScraper {
    private let storeID: UUID                 // persisted; same store as the login WebView
    init(storeID: UUID) { self.storeID = storeID }

    private func makeHeadlessPage() -> WebPage {
        var config = WebPage.Configuration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)   // reuse logged-in session
        return WebPage(configuration: config)
    }

    /// User-triggered. Returns clean post text for the sentiment analyst.
    func hotPosts(symbol: String) async throws -> [String] {
        let page = makeHeadlessPage()
        let url  = URL(string: "https://xueqiu.com/S/\(symbol)")!     // e.g. SH600519

        // await load settle: load(_:) RETURNS the event stream; iterate to `.finished`.
        // A failure is THROWN as WebPage.NavigationError (no `.failed` case). Wrap in a
        // timeout watchdog in real code; a login wall surfaces via a redirect / DOM probe.
        let events = page.load(URLRequest(url: url))
        for try await event in events {
            if case .finished = event { break }
        }

        // extract just the post text (token-cheap), keys become JS locals
        let raw = try await page.callJavaScript("""
            const nodes = document.querySelectorAll(sel);
            return [...nodes].slice(0, limit)
                   .map(n => n.innerText.trim())
                   .filter(t => t.length > 0);
            """,
            arguments: ["sel": ".timeline__item .content, .status-content",  // versioned per-adapter
                        "limit": 30]
        ) as? [String]

        return raw ?? []
    }
}
```

(Selectors above — and those in the prototype's `XueqiuProbe.swift` — are **placeholders pending validation against the live 雪球 DOM**; that validation is itself a finding for the eventual per-site adapter. Finalize during implementation and keep them in a versioned adapter.)

---

## 9. Risks, open questions, recommendation

### Risks
- **DOM brittleness.** Site redesigns break selectors. Mitigate with per-site versioned adapters + a "this adapter needs an update" UX, not a crash.
- **Anti-bot / Cloudflare.** Logged-in real sessions help; human-paced, low-volume, user-triggered access helps. No fingerprint evasion.
- **ToS gray area.** Defensible *because* it's the user's own data/session/device, opt-in, ephemeral, with a notice — but it's not zero-risk; keep it off by default and clearly disclosed.
- **API maturity.** `WebPage` is 26.0-new; expect rough edges in headless navigation-event timing. Prefer iterating the navigation-event stream `load` returns (with a timeout watchdog) over `isLoading` for deterministic awaits.
- **Broker MFA churn.** Some brokers expire sessions aggressively; re-login may be frequent. Acceptable for a user-triggered "refresh holdings."

### Open questions
1. **(Linchpin B — headless SPA render.) ✅ MOOT, resolved by the in-WebKit JSON-API path.** We never need the SPA to paint: the production path issues same-origin `fetch`es from a headless page loaded at the light root and reads JSON, so `requestAnimationFrame`/visibility signals are irrelevant for 雪球. (The point still stands for X — §6.1 — which has no equivalent clean JSON surface and should use an attached-but-hidden `WebView`.)
2. **(Linchpin A — Mode 1 cross-store cookie visibility.) ✅ VALIDATED (probe `8a73738`).** A headless `WebPage` bound to a named `WKWebsiteDataStore(forIdentifier:)` **does** inherit the cookie written by the visible login `WebView` on the same identifier — the probe's authenticated same-origin `fetch` returned logged-in JSON. The production scraper relies on exactly this. (Real end-to-end use still requires the user to be logged-in + the `enableXueqiuSentiment` opt-in flag on; both are off by default by design.)
3. **(Mode 2 probe portability.)** Can the proactive logged-in probe be made **site-agnostic enough to reuse** across 雪球 / 推特 / brokers — i.e. is "login-form-present ⇒ logged out" + a per-site logged-in marker a reliable, low-maintenance contract — or does each site need a bespoke probe? Determines how much of Mode 2 is shared vs per-adapter.
4. **(Mode 3 trigger fidelity.)** What signal cleanly distinguishes "endpoint blocked us, escalate to browser transport" from an ordinary transient error or a genuinely empty payload, so we don't pay the WebKit cost on every miss? (Empty body + prior-success heuristic; tune against the observed EastMoney IP-block behaviour.)
5. Whether 雪球 / each broker serves hot-posts/holdings as real DOM text vs canvas (determines DOM-vs-OCR per adapter).

### Recommendation & next steps
**Proceed with a thin, app-target `BrowserSessionManager` exposing `WebSessionProvider` + `WebScrapeProvider` (Modes 1–2) and `BrowserHTTPTransport` (Mode 3), prototyped on 雪球 BYO-cookie**, conforming to the package's existing `SocialSentimentProvider` seam with `requiresUserCredentials`/`interactiveOnly` enforced. Suggested order:

1. **Mode 1 on 雪球** — named persistent store, visible login once, headless reuse; confirm open question 2 (cross-store cookie visibility) first.
2. **Mode 2 status state machine** — proactive probe + reactive redirect capture, surfaced as the per-source `valid ✓ / expiring ⚠ / expired ✗` row; auto-pause on `expired ✗`.
3. **Mode 3 browser transport** — wire `BrowserHTTPTransport` as the fallback into the EastMoney/Yahoo chains behind the existing per-day cache + `HTTPRateLimiter`; trigger only on block/empty-response.
4. Only then generalize Mode 1 to **X/Reddit** (expect lower reliability on X) and broker adapters.

This adds real local capability with no backend, keeps all WebKit in the app target, and is fully consistent with Wick's BYO-everything model and existing guardrails.

---

## Sources
- WWDC25 Session 231, "Meet WebKit for SwiftUI" — <https://developer.apple.com/videos/play/wwdc2025/231/>
- Apple docs: `WebPage` — <https://developer.apple.com/documentation/webkit/webpage>
- Apple docs: `callJavaScript(_:arguments:in:contentWorld:)` — <https://developer.apple.com/documentation/webkit/webpage/calljavascript(_:arguments:in:contentworld:)>
- Apple docs: `WKWebsiteDataStore` — <https://developer.apple.com/documentation/webkit/wkwebsitedatastore>
- Apple docs: `callAsyncJavaScript(_:arguments:in:contentWorld:)` (arguments-as-locals semantics) — <https://developer.apple.com/documentation/webkit/wkwebview/callasyncjavascript(_:arguments:in:contentworld:)>
- WebKit blog: "Building Profiles with new WebKit API" (`dataStore(forIdentifier:)`) — <https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/>
- "Replacing Server-Side AI Search with iOS 26's New Headless Browser" — <https://folding-sky.com/blog/ios-26-macos-26-swiftui-headless-browser-webpage-webview>
- TrozWare, "SwiftUI WebView" — <https://troz.net/post/2025/swiftui-webview/>
- Daniel Saidi, "WebView is Finally Coming to SwiftUI" — <https://danielsaidi.com/blog/2025/06/10/webview-is-finally-coming-to-swiftui>
- Itsuki, "SwiftUI: Huge Dive into The Native WebView & WebPage" — <https://levelup.gitconnected.com/swiftui-huge-dive-into-the-native-webview-webpage-f0c365d057cc>
- AppCoda, "Exploring WebView and WebPage in SwiftUI for iOS 26" — <https://www.appcoda.com/swiftui-webview/>
