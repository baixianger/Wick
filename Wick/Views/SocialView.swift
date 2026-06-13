import SwiftUI
import TradingFloor
#if canImport(WebKit)
import WebKit
#endif

// MARK: - Social tab

/// Per-stock **Social** tab — surfaces 雪球 (Xueqiu) discussion for the selected
/// ticker, plus a clearly-labelled placeholder for X (Twitter) that ships later.
///
/// **BYO / off-by-default / user-triggered (ban-safety).** Nothing is fetched
/// until the user has logged into 雪球 once (the cookie lives in the app-scoped
/// `BrowserSessionManager`'s named WebKit store). On appear we fetch *only* if a
/// valid session already exists; otherwise the tab sits in its connect / empty
/// state. There is no auto-polling — refresh is an explicit button — and a
/// per-symbol-per-day cache means re-selecting the tab (or switching away and
/// back) doesn't re-hit 雪球.
///
/// **Data path.** The structured posts come from
/// `BrowserSessionManager.posts(for:)` (the UI-facing seam, distinct from the
/// sentiment decorator's `discussion(for:) -> [String]`), which runs the same
/// same-origin `/statuses/search.json` fetch and parses it into `XueqiuPost`
/// (author, text, 赞/评, time, url) via the package's pure `XueqiuPostParser`.
///
/// **Availability.** The whole 雪球 path is `WebPage`-backed and therefore
/// macOS-26-only. `AgentRuntime.browserSession` is typed `AnyObject?` and is
/// `nil` below 26, so we gate on `if #available` + cast; the unsupported floor
/// renders a graceful explainer rather than a broken control.
struct SocialView: View {
    let ticker: Ticker

    @Environment(AgentRuntime.self) private var runtime
    @Environment(AgentSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    /// Cached fetch result, keyed by symbol+day so re-entry doesn't refetch.
    @State private var model = SocialModel()
    /// Login sheet visibility — presents the manager's visible `loginPage`.
    @State private var loginSheetShown = false

    /// X (Twitter) cached fetch result + state, keyed by symbol+day. Separate
    /// from the 雪球 `model` so the two sources never share loading / cache state.
    @State private var xModel = XSocialModel()
    /// X login sheet visibility — presents the manager's visible `xLoginPage`.
    @State private var xLoginSheetShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // 雪球 is shown ONLY for A-share / HK tickers; US / other markets get
            // the X section alone (no 雪球 section, no "暂不支持" state).
            if isXueqiuEligible {
                xueqiuSection
                Divider().opacity(0.4)
            }
            xSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: ticker.id) {
            // First-appear fetch ONLY if a valid session already exists — never
            // surface a login prompt or hit the network unprompted.
            if isXueqiuEligible {
                await model.loadIfSessionReady(symbol: ticker.symbol,
                                               session: sessionManager)
            }
            // X is the mirror gate: shown for the OTHER (US / intl) markets, and
            // only when the BYO browser flag is on. Same "fetch only if a valid
            // session already exists" contract — never prompts / hits the network
            // unprompted.
            if isXEligible {
                await xModel.loadIfSessionReady(symbol: ticker.symbol,
                                                session: sessionManager)
            }
        }
    }

    /// Whether this ticker's market carries a 雪球 section at all. 雪球 discussion
    /// is gated **by market** — A-share (.SS/.SZ) and Hong Kong (.HK) only. US /
    /// other tickers omit 雪球 entirely (no section, no "暂不支持" state) and show
    /// the X placeholder alone. `parse` normalizes any stored CN/HK form
    /// (`0700.HK`, `00700`, `HK0700`, `700`) to canonical before we read its
    /// `Market`; non-CN inputs fail `parse` and fall back to the raw symbol,
    /// which then has no `Market` → ineligible.
    private var isXueqiuEligible: Bool {
        let canonical = CNSymbol.parse(ticker.symbol) ?? ticker.symbol
        switch CNSymbol.market(canonical) {
        case .shanghai, .shenzhen, .hongKong: return true
        case .none: return false
        }
    }

    /// Whether this ticker's market carries an X (Twitter) section. X is the
    /// mirror of `isXueqiuEligible`: it covers the OTHER markets — US / intl,
    /// i.e. anything 雪球 does NOT (cashtags like `$TSLA` are X's US-equity idiom).
    /// So a ticker shows EITHER 雪球 (CN/HK) OR X (everything else), never both.
    private var isXEligible: Bool { !isXueqiuEligible }

    // MARK: - 雪球 section

    @ViewBuilder
    private var xueqiuSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader

            if #available(macOS 26.0, *), let session = sessionManager {
                content(session: session)
            } else {
                unsupportedState
            }
        }
    }

    /// Header row: 雪球 source label + the "as of" timestamp + refresh control.
    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            sourceBadge(text: "雪球", tint: blueTint)
            Text("Discussion")
                .font(.system(size: 18, weight: .semibold))
            if let asOf = model.asOf {
                Text("· as of \(asOf.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if #available(macOS 26.0, *), sessionManager != nil {
                refreshButton
            }
        }
    }

    /// State machine inside the 雪球 section (macOS 26 only). Order of
    /// precedence: not-connected → loading → empty → cards. Market eligibility
    /// (A-share / HK) is gated upstream in `body`, so this section only ever
    /// renders for tickers 雪球 covers.
    @available(macOS 26.0, *)
    @ViewBuilder
    private func content(session: BrowserSessionManager) -> some View {
        if !session.status.canScrape {
            notConnectedState(session: session)
        } else if model.isLoading {
            loadingState
        } else if model.posts.isEmpty {
            emptyState(session: session)
        } else {
            postList
        }
    }

    // MARK: States

    /// (a) Session invalid / never connected → "连接雪球" empty state. Logging in
    /// opens the manager's visible `loginPage` in a sheet; on dismiss we re-probe
    /// the session so the state machine advances.
    @available(macOS 26.0, *)
    private func notConnectedState(session: BrowserSessionManager) -> some View {
        emptyCard(icon: "person.crop.circle.badge.questionmark",
                  title: "Not connected to 雪球",
                  message: String(localized: "Sign in to 雪球 to view discussion for this ticker. Your session stays on this device, is triggered on demand, and is never scraped automatically.", locale: LocaleHolder.current)) {
            Button {
                session.login()
                loginSheetShown = true
            } label: {
                Label("Connect 雪球", systemImage: "link")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(LiquidGlassButtonStyle(prominent: true))
        }
        .sheet(isPresented: $loginSheetShown) {
            loginSheet(session: session)
        }
    }

    /// (b) Connected but nothing fetched yet → "点击刷新" empty state.
    @available(macOS 26.0, *)
    private func emptyState(session: BrowserSessionManager) -> some View {
        emptyCard(icon: "bubble.left.and.bubble.right",
                  title: "No discussion",
                  message: model.didLoadOnce
                      ? String(localized: "雪球 returned no recent discussion for this ticker. Try refreshing later.", locale: LocaleHolder.current)
                      : String(localized: "Tap refresh to load 雪球 discussion for this ticker.", locale: LocaleHolder.current)) {
            Button {
                Task { await model.refresh(symbol: ticker.symbol, session: session) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(LiquidGlassButtonStyle(prominent: true))
        }
    }

    /// (c) Posts → scrollable card list. The outer DetailView already provides a
    /// ScrollView, so we lay the cards out in a plain VStack and let that scroll.
    @available(macOS 26.0, *)
    private var postList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.posts) { post in
                postCard(post)
            }
        }
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading 雪球 discussion…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    /// Below macOS 26 the `WebPage` API floor isn't met → explain rather than
    /// expose a dead control.
    private var unsupportedState: some View {
        emptyCard(icon: "exclamationmark.triangle",
                  title: "Requires macOS 26",
                  message: String(localized: "雪球 discussion relies on the embedded WebKit (WebPage) capability, which needs macOS 26 or later.", locale: LocaleHolder.current)) { EmptyView() }
    }

    // MARK: Card

    /// One discussion card — author, body, 赞/评 counts, relative time, a 雪球
    /// source badge. Glass surface (`liquidGlass`). Tapping opens the post's
    /// permalink in the default browser when present.
    @available(macOS 26.0, *)
    @ViewBuilder
    private func postCard(_ post: XueqiuPost) -> some View {
        let tappable = post.url != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text(post.author.isEmpty ? String(localized: "雪球 user", locale: LocaleHolder.current) : post.author)
                    .font(.system(size: 13, weight: .semibold))
                sourceBadge(text: "雪球", tint: blueTint)
                Spacer(minLength: 0)
                if let when = post.createdAt {
                    Text(Self.relativeFormatter.localizedString(for: when, relativeTo: Date()))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Text(post.text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 16) {
                Label("\(post.likeCount)", systemImage: "hand.thumbsup")
                Label("\(post.replyCount)", systemImage: "bubble.right")
                Spacer(minLength: 0)
                if tappable {
                    Image(systemName: "arrow.up.forward.square")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 12)
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture {
            if let url = post.url { openURL(url) }
        }
        .help(tappable ? String(localized: "Open in browser", locale: LocaleHolder.current) : "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(post.author.isEmpty ? "雪球用户" : post.author): \(post.text). 赞 \(post.likeCount), 评 \(post.replyCount)")
        .accessibilityAddTraits(tappable ? .isLink : [])
    }

    // MARK: Login sheet

    /// Presents the manager's visible login `WebPage` so the user can sign in
    /// (password / SMS / captcha — all human-in-the-loop). Dismissing re-probes
    /// the session so the state machine advances to `.valid`.
    @available(macOS 26.0, *)
    @ViewBuilder
    private func loginSheet(session: BrowserSessionManager) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to 雪球")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    loginSheetShown = false
                    Task {
                        await session.refreshStatus()
                        // If the session is now usable, pull posts immediately so
                        // the user lands on content rather than the empty state.
                        if session.status.canScrape {
                            await model.refresh(symbol: ticker.symbol, session: session)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            #if canImport(WebKit)
            WebView(session.loginPage)
                .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        .frame(minWidth: 560, minHeight: 640)
    }

    // MARK: - X (Twitter) section

    /// The X (Twitter) discussion section, shown for US / intl tickers (the
    /// mirror of the 雪球 gate). Same BYO shape as 雪球 — nothing is fetched until
    /// the user has logged into X once (cookie in the X named WebKit store), and
    /// there is no auto-polling (refresh is an explicit button).
    ///
    /// **Production technique.** Posts come from `BrowserSessionManager.xPosts(for:)`,
    /// which runs the VALIDATED, ban-safe single-shot search: navigate the
    /// persistent headless `WebPage` ONCE to the human `/search?q=$SYMBOL&f=live`
    /// URL, let X's own JS issue the request, then ONE DOM read of the rendered
    /// `<article data-testid="tweet">` nodes. We never raw-fetch X's GraphQL (that
    /// needs an unforgeable `x-client-transaction-id`).
    ///
    /// **Gating.** BYO-only, behind the experimental `enableWickerBrowser` flag —
    /// the same flag that powers the Wicker browser. Flag off (or pre-macOS-26) →
    /// a clean "需要开启 BYO 浏览器" state, never a crash.
    @ViewBuilder
    private var xSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            xSectionHeader

            if !settings.enableWickerBrowser {
                xDisabledState
            } else if #available(macOS 26.0, *), let session = sessionManager {
                xContent(session: session)
            } else {
                unsupportedState
            }
        }
    }

    /// Header row: X source label + the "as of" timestamp + refresh control.
    private var xSectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            sourceBadge(text: "X", tint: .secondary)
            Text("X (Twitter)")
                .font(.system(size: 18, weight: .semibold))
            if let asOf = xModel.asOf {
                Text("· as of \(asOf.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if settings.enableWickerBrowser,
               #available(macOS 26.0, *), sessionManager != nil {
                xRefreshButton
            }
        }
    }

    /// State machine inside the X section (macOS 26 + flag on). Order of
    /// precedence mirrors 雪球: not-connected → loading → empty → cards.
    @available(macOS 26.0, *)
    @ViewBuilder
    private func xContent(session: BrowserSessionManager) -> some View {
        if !session.xStatus.canScrape {
            xNotConnectedState(session: session)
        } else if xModel.isLoading {
            xLoadingState
        } else if xModel.posts.isEmpty {
            xEmptyState(session: session)
        } else {
            xPostList
        }
    }

    /// Flag-off / pre-opt-in state — explain the BYO browser must be enabled
    /// rather than expose a dead control. Points at Settings → Workflow.
    private var xDisabledState: some View {
        emptyCard(icon: "globe.badge.chevron.backward",
                  title: "BYO browser required",
                  message: String(localized: "X (Twitter) discussion uses the same BYO (bring-your-own account) approach. Enable the embedded browser under Settings → Workflow, then sign in to X to view discussion for this ticker.", locale: LocaleHolder.current)) { EmptyView() }
    }

    /// (a) X session invalid / never connected → "登录 X" empty state. Logging in
    /// opens the manager's visible `xLoginPage` in a sheet; on dismiss we re-probe
    /// the X session so the state machine advances.
    @available(macOS 26.0, *)
    private func xNotConnectedState(session: BrowserSessionManager) -> some View {
        emptyCard(icon: "person.crop.circle.badge.questionmark",
                  title: "Not signed in to X",
                  message: String(localized: "Sign in to X (Twitter) to view discussion for this ticker. Your session stays on this device, is triggered on demand, and is never scraped automatically.", locale: LocaleHolder.current)) {
            Button {
                session.xLogin()
                xLoginSheetShown = true
            } label: {
                Label("Sign in to X", systemImage: "link")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(LiquidGlassButtonStyle(prominent: true))
        }
        .sheet(isPresented: $xLoginSheetShown) {
            xLoginSheet(session: session)
        }
    }

    /// (b) Connected but nothing fetched yet → "点击刷新" empty state.
    @available(macOS 26.0, *)
    private func xEmptyState(session: BrowserSessionManager) -> some View {
        emptyCard(icon: "bubble.left.and.bubble.right",
                  title: "No discussion",
                  message: xModel.didLoadOnce
                      ? String(localized: "X returned no recent discussion for this ticker. Try refreshing later.", locale: LocaleHolder.current)
                      : String(localized: "Tap refresh to load X discussion for this ticker.", locale: LocaleHolder.current)) {
            Button {
                Task { await xModel.refresh(symbol: ticker.symbol, session: session) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(LiquidGlassButtonStyle(prominent: true))
        }
    }

    /// (c) Posts → card list. The outer DetailView already provides a ScrollView,
    /// so we lay the cards out in a plain VStack and let that scroll.
    @available(macOS 26.0, *)
    private var xPostList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(xModel.posts) { post in
                xPostCard(post)
            }
        }
    }

    private var xLoadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading X discussion…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    /// One X discussion card — author handle, body, an X source badge. Tapping
    /// opens the author's X profile (the DOM read carries no per-tweet permalink,
    /// so the `@handle` profile is the best stable destination). Glass surface.
    @available(macOS 26.0, *)
    @ViewBuilder
    private func xPostCard(_ post: XPost) -> some View {
        let profileURL = Self.xProfileURL(handle: post.handle)
        let tappable = profileURL != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text(post.handle.isEmpty ? String(localized: "X user", locale: LocaleHolder.current) : post.handle)
                    .font(.system(size: 13, weight: .semibold))
                sourceBadge(text: "X", tint: .secondary)
                Spacer(minLength: 0)
                if tappable {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Text(post.text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 12)
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture {
            if let url = profileURL { openURL(url) }
        }
        .help(tappable ? String(localized: "Open author profile in browser", locale: LocaleHolder.current) : "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(post.handle.isEmpty ? "X 用户" : post.handle): \(post.text)")
        .accessibilityAddTraits(tappable ? .isLink : [])
    }

    @available(macOS 26.0, *)
    private var xRefreshButton: some View {
        Button {
            if let session = sessionManager {
                Task { await xModel.refresh(symbol: ticker.symbol, session: session) }
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.plain)
        .disabled(xModel.isLoading || sessionManager?.xStatus.canScrape != true)
        .help("Refresh X discussion")
        .accessibilityLabel("Refresh")
    }

    /// Presents the manager's visible X login `WebPage` so the user can sign in
    /// (password / 2FA / any automation challenge — all human-in-the-loop).
    /// Dismissing re-probes the X session so the state machine advances to
    /// `.valid`. Mirrors the 雪球 `loginSheet`.
    @available(macOS 26.0, *)
    @ViewBuilder
    private func xLoginSheet(session: BrowserSessionManager) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to X (Twitter)")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    xLoginSheetShown = false
                    Task {
                        await session.xRefreshStatus()
                        // If the X session is now usable, pull posts immediately so
                        // the user lands on content rather than the empty state.
                        if session.xStatus.canScrape {
                            await xModel.refresh(symbol: ticker.symbol, session: session)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            #if canImport(WebKit)
            WebView(session.xLoginPage)
                .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        .frame(minWidth: 560, minHeight: 640)
    }

    /// Build the `https://x.com/<handle>` profile URL for a tweet author handle
    /// (`@elonmusk` → `https://x.com/elonmusk`). `nil` for an empty / malformed
    /// handle, so the card renders non-tappable.
    private static func xProfileURL(handle: String) -> URL? {
        let bare = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        let trimmed = bare.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }
        return URL(string: "https://x.com/\(trimmed)")
    }

    // MARK: - Shared pieces

    /// Reusable empty / state card. `action` slots the primary affordance (or an
    /// `EmptyView`) under the explainer text.
    @ViewBuilder
    private func emptyCard<Action: View>(
        icon: String,
        title: LocalizedStringKey,
        message: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            action()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .liquidGlass(cornerRadius: 14)
    }

    /// Small source-label pill (雪球 / X). Semantic colours only, so the known
    /// glass-appearance-lag issue doesn't strand a hardcoded tone on a scheme
    /// flip.
    private func sourceBadge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    @available(macOS 26.0, *)
    private var refreshButton: some View {
        Button {
            if let session = sessionManager {
                Task { await model.refresh(symbol: ticker.symbol, session: session) }
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.plain)
        .disabled(model.isLoading || sessionManager?.status.canScrape != true)
        .help("Refresh 雪球 discussion")
        .accessibilityLabel("Refresh")
    }

    // MARK: - Wiring

    /// The app-scoped 雪球 session owner, cast out of the environment's
    /// `AnyObject?` (nil below macOS 26). Read on demand so the view doesn't hold
    /// the manager directly — its lifecycle is owned by `AgentRuntime`.
    @available(macOS 26.0, *)
    private var sessionManager: BrowserSessionManager? {
        runtime.browserSession as? BrowserSessionManager
    }

    /// Semantic blue that reads on both light + dark (雪球 brand-adjacent
    /// without hardcoding a fixed RGB that the glass-lag issue could strand).
    private var blueTint: Color { .blue }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - View model

/// View-local cache + fetch state for the Social tab's 雪球 posts. Keyed by
/// `symbol + calendar-day` so re-selecting the tab within the same day reuses
/// the last result instead of re-hitting 雪球 (ban-safety + snappy re-entry).
/// `@Observable` so the view tracks `isLoading` / `posts` / `asOf` transitions.
@Observable
@MainActor
final class SocialModel {
    /// The posts currently shown (most-recent-first as 雪球 returns them).
    private(set) var posts: [XueqiuPost] = []
    /// In-flight fetch flag, drives the spinner + disables refresh.
    private(set) var isLoading = false
    /// When the shown posts were fetched — surfaces the "as of <time>" label.
    private(set) var asOf: Date?
    /// True once any fetch (even an empty one) has completed, so the empty
    /// state can distinguish "not loaded yet" from "loaded, 雪球 had nothing".
    private(set) var didLoadOnce = false

    /// Cache key of the currently-held posts (`symbol|yyyy-ddd`).
    private var cacheKey: String?

    /// Fetch on first appear ONLY when a valid session already exists — never
    /// prompt for login or hit the network unprompted. No-op (cache hit) when
    /// we already hold today's posts for this symbol.
    @available(macOS 26.0, *)
    func loadIfSessionReady(symbol: String,
                            session: BrowserSessionManager?) async {
        guard let session else { return }
        let key = Self.key(symbol: symbol)
        if cacheKey == key, !posts.isEmpty { return }   // same-day cache hit
        // Only probe when we don't already know the session is usable. Re-probing
        // a warm/valid session can transiently downgrade it (the cold
        // `/hots.json` probe), which bails the auto-load and forces a manual
        // refresh every time — the bug we're fixing.
        if !session.status.canScrape {
            await session.refreshStatus()
        }
        guard session.status.canScrape else {
            resetFor(symbol: symbol)
            return
        }
        // Cold-start resilience: on first open the 雪球 WebPage may still be
        // warming, so the same-origin fetch can return empty even with a valid
        // session. Retry a couple times before settling into the empty state so
        // the user doesn't have to hit refresh manually.
        for attempt in 1...3 {
            await fetch(symbol: symbol, session: session, key: key)
            if !posts.isEmpty { break }
            if attempt < 3 { try? await Task.sleep(for: .milliseconds(700)) }
        }
    }

    /// User-triggered refresh — always re-fetches (bypasses the same-day cache),
    /// since the user explicitly asked for fresh data.
    @available(macOS 26.0, *)
    func refresh(symbol: String, session: BrowserSessionManager) async {
        await fetch(symbol: symbol, session: session, key: Self.key(symbol: symbol))
    }

    @available(macOS 26.0, *)
    private func fetch(symbol: String,
                       session: BrowserSessionManager,
                       key: String) async {
        isLoading = true
        let fetched = await session.posts(for: symbol)
        isLoading = false
        didLoadOnce = true
        cacheKey = key
        asOf = Date()
        posts = fetched
    }

    /// Drop cached posts when the symbol changes to one we won't fetch (so the
    /// previous ticker's discussion doesn't linger under a new symbol).
    private func resetFor(symbol: String) {
        let key = Self.key(symbol: symbol)
        if cacheKey != key {
            posts = []
            asOf = nil
            didLoadOnce = false
            cacheKey = nil
        }
    }

    /// `symbol|<year>-<day-of-year>` — stable within a calendar day.
    private static func key(symbol: String) -> String {
        let c = Calendar.current.dateComponents([.year, .dayOfYear], from: Date())
        return "\(symbol)|\(c.year ?? 0)-\(c.dayOfYear ?? 0)"
    }
}

// MARK: - X (Twitter) view model

/// View-local cache + fetch state for the Social tab's X (Twitter) posts. The
/// exact sibling of `SocialModel` for the 雪球 path — keyed by `symbol +
/// calendar-day` so re-selecting the tab within the same day reuses the last
/// result instead of re-hitting X (ban-safety + snappy re-entry). `@Observable`
/// so the view tracks `isLoading` / `posts` / `asOf` transitions. Kept separate
/// from `SocialModel` so the two sources never share loading / cache state.
@Observable
@MainActor
final class XSocialModel {
    /// The posts currently shown (search order, most-relevant/recent first).
    private(set) var posts: [XPost] = []
    /// In-flight fetch flag, drives the spinner + disables refresh.
    private(set) var isLoading = false
    /// When the shown posts were fetched — surfaces the "as of <time>" label.
    private(set) var asOf: Date?
    /// True once any fetch (even an empty one) has completed, so the empty state
    /// can distinguish "not loaded yet" from "loaded, X had nothing".
    private(set) var didLoadOnce = false

    /// Cache key of the currently-held posts (`symbol|yyyy-ddd`).
    private var cacheKey: String?

    /// Fetch on first appear ONLY when a valid X session already exists — never
    /// prompt for login or hit the network unprompted. No-op (cache hit) when we
    /// already hold today's posts for this symbol.
    @available(macOS 26.0, *)
    func loadIfSessionReady(symbol: String,
                            session: BrowserSessionManager?) async {
        guard let session else { return }
        let key = Self.key(symbol: symbol)
        if cacheKey == key, !posts.isEmpty { return }   // same-day cache hit
        // Only probe when we don't already know the X session is usable —
        // re-probing a warm/valid session can transiently downgrade it and bail
        // the auto-load. (The X scraper itself polls for the async-rendered
        // tweets, so no empty-retry is needed here.)
        if !session.xStatus.canScrape {
            await session.xRefreshStatus()
        }
        guard session.xStatus.canScrape else {
            resetFor(symbol: symbol)
            return
        }
        await fetch(symbol: symbol, session: session, key: key)
    }

    /// User-triggered refresh — always re-fetches (bypasses the same-day cache),
    /// since the user explicitly asked for fresh data.
    @available(macOS 26.0, *)
    func refresh(symbol: String, session: BrowserSessionManager) async {
        await fetch(symbol: symbol, session: session, key: Self.key(symbol: symbol))
    }

    @available(macOS 26.0, *)
    private func fetch(symbol: String,
                       session: BrowserSessionManager,
                       key: String) async {
        isLoading = true
        let fetched = await session.xPosts(for: symbol)
        isLoading = false
        didLoadOnce = true
        cacheKey = key
        asOf = Date()
        posts = fetched
    }

    /// Drop cached posts when the symbol changes to one we won't fetch (so the
    /// previous ticker's discussion doesn't linger under a new symbol).
    private func resetFor(symbol: String) {
        let key = Self.key(symbol: symbol)
        if cacheKey != key {
            posts = []
            asOf = nil
            didLoadOnce = false
            cacheKey = nil
        }
    }

    /// `symbol|<year>-<day-of-year>` — stable within a calendar day.
    private static func key(symbol: String) -> String {
        let c = Calendar.current.dateComponents([.year, .dayOfYear], from: Date())
        return "\(symbol)|\(c.year ?? 0)-\(c.dayOfYear ?? 0)"
    }
}
