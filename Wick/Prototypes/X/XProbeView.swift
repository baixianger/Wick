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
}
