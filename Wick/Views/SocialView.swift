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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    /// Cached fetch result, keyed by symbol+day so re-entry doesn't refetch.
    @State private var model = SocialModel()
    /// Login sheet visibility — presents the manager's visible `loginPage`.
    @State private var loginSheetShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            xueqiuSection
            Divider().opacity(0.4)
            xPlaceholderSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: ticker.id) {
            // First-appear fetch ONLY if a valid session already exists — never
            // surface a login prompt or hit the network unprompted.
            await model.loadIfSessionReady(symbol: ticker.symbol,
                                           session: sessionManager)
        }
    }

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
    /// precedence: unsupported-symbol → not-connected → loading → empty → cards.
    @available(macOS 26.0, *)
    @ViewBuilder
    private func content(session: BrowserSessionManager) -> some View {
        // `xueqiuSymbol` parse-normalizes internally, so any CN/HK form the user
        // can store (`0700.HK`, `00700`, `HK0700`, `700`) clears the gate — only
        // genuinely non-CN tickers fall through to the unsupported state.
        if CNSymbol.xueqiuSymbol(ticker.symbol) == nil {
            unsupportedSymbolState
        } else if !session.status.canScrape {
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
                  title: "未连接雪球",
                  message: "登录雪球后即可查看该标的的讨论。登录态仅保存在本机，按需触发，不会自动抓取。") {
            Button {
                session.login()
                loginSheetShown = true
            } label: {
                Label("连接雪球", systemImage: "link")
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
                  title: "暂无讨论",
                  message: model.didLoadOnce
                      ? "雪球未返回该标的的最新讨论。可稍后再刷新。"
                      : "点击刷新以加载该标的的雪球讨论。") {
            Button {
                Task { await model.refresh(symbol: ticker.symbol, session: session) }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
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
            Text("正在加载雪球讨论…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    /// 雪球 / our-mapping doesn't cover this ticker (non-CN/HK).
    private var unsupportedSymbolState: some View {
        emptyCard(icon: "globe.asia.australia",
                  title: "雪球暂不支持该标的",
                  message: "雪球讨论目前覆盖 A 股与港股标的（如 600519.SS、0700.HK）。") { EmptyView() }
    }

    /// Below macOS 26 the `WebPage` API floor isn't met → explain rather than
    /// expose a dead control.
    private var unsupportedState: some View {
        emptyCard(icon: "exclamationmark.triangle",
                  title: "需要 macOS 26",
                  message: "雪球讨论依赖内嵌 WebKit（WebPage）能力，需 macOS 26 及以上。") { EmptyView() }
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
                Text(post.author.isEmpty ? "雪球用户" : post.author)
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
        .help(tappable ? "在浏览器中打开" : "")
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
                Text("登录雪球")
                    .font(.headline)
                Spacer()
                Button("完成") {
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

    // MARK: - X (Twitter) placeholder

    /// Clearly-labelled, disabled section so the tab's two-source shape is
    /// visible while X stays unwired. NOT a `#if DEBUG` stub — it's a real,
    /// shipped "coming soon" affordance.
    private var xPlaceholderSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                sourceBadge(text: "X", tint: .secondary)
                Text("X (Twitter)")
                    .font(.system(size: 18, weight: .semibold))
                Text("即将接入")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                Spacer(minLength: 0)
            }
            emptyCard(icon: "clock.badge",
                      title: "X 讨论即将接入",
                      message: "X (Twitter) 讨论将沿用同样的 BYO（自带账号）方式接入，敬请期待。") { EmptyView() }
                .disabled(true)
                .opacity(0.7)
        }
    }

    // MARK: - Shared pieces

    /// Reusable empty / state card. `action` slots the primary affordance (or an
    /// `EmptyView`) under the explainer text.
    @ViewBuilder
    private func emptyCard<Action: View>(
        icon: String,
        title: String,
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
        .help("刷新雪球讨论")
        .accessibilityLabel("刷新")
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
        // Re-probe cheaply; only fetch if the probe says the session is usable.
        await session.refreshStatus()
        guard session.status.canScrape else {
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
