import SwiftUI
import WebKit

/// **Dev-only** SwiftUI surface for `XProbe`. NOT in the user-facing navigation
/// — reachable only from the `#if DEBUG` "Developer" menu (see `WickApp`),
/// alongside the 雪球 probe. Where the 雪球 probe validated a friendly target,
/// this one INTERROGATES the hard one (X / Twitter) and HONESTLY REPORTS which
/// retrieval path is reachable:
///
///   1. Sign into X once in the visible `WebView` on the left.
///   2. Tap "重新加载无头页" so the persistent headless page re-parks at `/home`
///      AFTER login (it was parked at `init`, pre-login, on the logged-out wall).
///   3. Tap "探测 X 数据" — runs, on that one persistent page (no re-nav):
///        • a session check (`ct0` cookie + logged-in DOM marker),
///        • **Path A** DOM read of the rendered timeline (count + samples),
///        • **Path B** API `fetch` (Bearer + `x-csrf-token`, no
///          `x-client-transaction-id`) — capturing the exact status/body.
///   3. Read the result card: DOM count + samples (Path A) and API status +
///      body slice (Path B) tell you, empirically, what's reachable.
///
/// Gated behind `if #available(macOS 26.0, *)` because `WebPage` / `WebView`
/// are 26-SDK-new.
@available(macOS 26.0, *)
struct XProbeView: View {

    @State private var probe = XProbe()
    /// Optional handle (no `@`) for Path B's `UserByScreenName` read. Empty ⇒
    /// Path B falls back to a `HomeTimeline` query. Defaults blank.
    @State private var screenName: String = ""
    @State private var result: XProbe.XProbeResult?
    @State private var running = false
    @State private var reparking = false

    /// Per-stock search query for the single-shot, ban-safe `searchStock`. Default
    /// a stock cashtag so the dev can one-click verify.
    @State private var searchQuery: String = "$TSLA"
    @State private var searchResult: XProbe.XSearchResult?
    @State private var searching = false
    /// In-flight guard for the element-driven search (`searchStockViaElement`),
    /// kept separate from `searching` so neither search button double-fires while
    /// the other runs.
    @State private var searchingViaElement = false

    var body: some View {
        HSplitView {
            // Left: the visible login browser. The user signs into X here once.
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("X 登录 (visible WebView)")
                        .font(.headline)
                    Spacer()
                    Button("重新加载") { probe.reloadLogin() }
                        .controlSize(.small)
                }
                .padding(10)

                WebView(probe.loginPage)
                    .frame(minWidth: 420, minHeight: 420)
            }

            // Right: the path explainer + controls + result.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    explainer

                    Divider()

                    controls

                    if let result {
                        resultCard(result)
                    }

                    Divider()

                    searchSection

                    if let searchResult {
                        searchResultCard(searchResult)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 380)
        }
        .frame(minWidth: 900, minHeight: 580)
        .navigationTitle("X (Twitter) 数据可达性 Probe (DEV)")
    }

    // MARK: - Pieces

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("两条探测路径 (X 是硬骨头)")
                .font(.title3.bold())
            Label {
                Text("**Path A — DOM 读取**（最可能成功）。直接读已渲染的首页时间线 `article[data-testid=\"tweet\"]` 节点，取 `tweetText` + 作者 handle。不需要任何特殊 header — 页面渲染了就能读到。")
            } icon: { Image(systemName: "doc.text.magnifyingglass") }
            Label {
                Text("**Path B — API 尝试**（记录差距）。同源 `fetch` 打 X GraphQL 读接口，带 `Bearer` + `x-csrf-token`(ct0) 但**缺** `x-client-transaction-id`（X 自己的 JS 才能算）。如实记录 HTTP 状态/响应体，常见 404(queryId 过期) 或 401/403(缺签名)。")
            } icon: { Image(systemName: "network") }

            Text("用法：① 左侧登录 X 一次 → ② 点「重新加载无头页」(登录后让无头页重新渲染 /home) → ③ 点「探测 X 数据」。无头页只加载一次、之后不再导航(避免 NSURLErrorDomain -999)。日志带 `[XProbe]` 前缀，Console.app 可查。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("@handle (Path B, 可选)")
                TextField("不带 @, 留空则打 HomeTimeline", text: $screenName)
                    .frame(width: 220)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Button {
                    repark()
                } label: {
                    if reparking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("重载中…")
                        }
                    } else {
                        Text("重新加载无头页")
                    }
                }
                .disabled(running || reparking)

                Button {
                    runProbe()
                } label: {
                    if running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("探测中…")
                        }
                    } else {
                        Text("探测 X 数据")
                    }
                }
                .disabled(running || reparking)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func resultCard(_ r: XProbe.XProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("结果")
                .font(.headline)

            row("已登录?", loggedInLabel(r.loggedIn))
            row("Path A 推文数", "\(r.domTweetCount) 条 article 节点")
            row("Path B API 状态", r.apiStatus, tint: r.apiStatus.hasPrefix("http 200") ? .green : .primary)
            if let err = r.error {
                row("错误", err, tint: .red)
            }

            if !r.domSamples.isEmpty {
                Text("Path A 文本样本")
                    .font(.subheadline.bold())
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(r.domSamples.enumerated()), id: \.offset) { _, s in
                        Text(s)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 8))
            }

            if !r.apiSample.isEmpty {
                Text("Path B 响应体 (前 700 字符)")
                    .font(.subheadline.bold())
                    .padding(.top, 4)
                Text(r.apiSample)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }

    // MARK: - Single-shot per-stock search

    /// The ban-safe search probe: ONE navigation to X's normal search URL per
    /// click, then a single DOM read. No raw GraphQL fetch, no polling, no retry.
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("个股搜索验证 (导航式 DOM 读取)")
                .font(.title3.bold())

            Text("导航无头页**一次**到 X 正常搜索 URL，让 X 自己的 JS 发请求，我们只读渲染出的结果 — 不直接打搜索 GraphQL(缺 `x-client-transaction-id`、queryId 易过期、更像机器人)。最低机器人特征。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("**元素搜索 (单次)**：不导航 URL，而是驱动 X 自己的搜索框元素 — focus → 用 React 原生 value setter 输入 → 派发 Enter 键序列，由 X 自己 UI 触发搜索并**客户端路由**到 `/search`(无页面加载、不触发导航事件，故脚本内有界轮询等结果)。更像真人、机器人特征更低。**需当前无头页在 /home 或 /explore(搜索框存在)**；若提示 `no-search-input`，先点「重新加载无头页」回到 /home。")
                .font(.callout)
                .foregroundStyle(.secondary)

            // On-screen CAUTION — ban-safety, in Chinese.
            Label {
                Text("单次请求/每次点按只发一次,请自行控制频率,避免触发 X 风控或封号;只读、不自动轮询。")
                    .font(.callout.bold())
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.orange)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))

            HStack {
                Text("搜索词")
                TextField("如 $TSLA", text: $searchQuery)
                    .frame(width: 220)
                    .textFieldStyle(.roundedBorder)

                Button {
                    runSearch()
                } label: {
                    if searching {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("搜索中…")
                        }
                    } else {
                        Text("验证个股搜索 (单次)")
                    }
                }
                .disabled(running || reparking || searching || searchingViaElement || searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)

                // Element-driven sibling: drives X's REAL search box (focus +
                // native-setter type + Enter) instead of navigating to a search
                // URL — more human-like, lower bot-signal. Same single-shot
                // contract; guarded by its own in-flight flag.
                Button {
                    runSearchViaElement()
                } label: {
                    if searchingViaElement {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("搜索中…")
                        }
                    } else {
                        Text("元素搜索 (单次)")
                    }
                }
                .disabled(running || reparking || searching || searchingViaElement || searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.bordered)
            }
        }
    }

    private func searchResultCard(_ r: XProbe.XSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("搜索结果")
                .font(.headline)

            row("推文数", "\(r.tweetCount) 条 article 节点")
            row("导航结果", r.navOutcome,
                tint: (r.navOutcome.hasPrefix("finished") || r.navOutcome.hasPrefix("client-routed")) ? .green : .primary)
            // Element-path diagnostics (nil for the URL-nav path — hidden then).
            if let selector = r.usedSelector {
                row("命中选择器", selector,
                    tint: selector == "no-search-input" ? .red : .primary)
            }
            if let finalURL = r.finalURL {
                row("最终 URL", finalURL,
                    tint: finalURL.contains("/search") ? .green : .primary)
            }
            if let err = r.error {
                row("错误", err, tint: .red)
            }

            if !r.samples.isEmpty {
                Text("文本样本")
                    .font(.subheadline.bold())
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(r.samples.enumerated()), id: \.offset) { _, s in
                        Text(s)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 8))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }

    private func row(_ key: String, _ value: String, tint: Color = .primary) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.callout)
                .foregroundStyle(tint)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func loggedInLabel(_ value: Bool?) -> String {
        switch value {
        case .some(true):  return "✓ 已登录 (ct0 + 登录标记)"
        case .some(false): return "✗ 未登录 (无 ct0 / 无标记)"
        case .none:        return "? 无法判断"
        }
    }

    // MARK: - Actions

    private func repark() {
        reparking = true
        Task {
            await probe.reparkHeadless()
            await MainActor.run { self.reparking = false }
        }
    }

    private func runProbe() {
        let sn = screenName
        running = true
        result = nil
        Task {
            let r = await probe.probe(screenName: sn)
            await MainActor.run {
                self.result = r
                self.running = false
            }
        }
    }

    /// Fire the single-shot, ban-safe per-stock search: ONE navigation + ONE DOM
    /// read per click. Guarded by `searching` so the button can't double-fire.
    private func runSearch() {
        let q = searchQuery
        searching = true
        searchResult = nil
        Task {
            let r = await probe.searchStock(query: q)
            await MainActor.run {
                self.searchResult = r
                self.searching = false
            }
        }
    }

    /// Fire the single-shot, ban-safe ELEMENT-DRIVEN search: ONE in-page script
    /// (find search box → native-setter type → Enter → bounded poll → DOM read)
    /// per click — no host navigation. Guarded by `searchingViaElement` so the
    /// button can't double-fire (and disabled while the URL-nav search runs).
    private func runSearchViaElement() {
        let q = searchQuery
        searchingViaElement = true
        searchResult = nil
        Task {
            let r = await probe.searchStockViaElement(query: q)
            await MainActor.run {
                self.searchResult = r
                self.searchingViaElement = false
            }
        }
    }
}
