import SwiftUI
import WebKit

/// **Dev-only** SwiftUI surface for `XueqiuProbe`. NOT in the user-facing
/// navigation — reachable only from the `#if DEBUG` "Developer" menu (see
/// `WickApp`). It exists to let a human validate the two BYO-cookie linchpins
/// by hand, since neither can be runtime-checked without a real 雪球 login:
///
///   1. Sign into 雪球 once in the visible `WebView` below.
///   2. Tap "提取讨论 (headless)" — that spins a *separate, headless* `WebPage`
///      on the *same* persistent store and tries to read the stock page.
///   3. Read the result card: `已登录?` answers linchpin A (cookie shared into
///      the headless page); a non-empty text sample answers linchpin B (the
///      headless SPA actually rendered).
///
/// Gated behind `if #available(macOS 26.0, *)` because `WebPage` / `WebView`
/// are 26-SDK-new.
@available(macOS 26.0, *)
struct XueqiuProbeView: View {

    @State private var probe = XueqiuProbe()
    /// Raw A-share code the user wants to probe; defaults to 贵州茅台 (600519),
    /// the doc's worked example. Mapped to 雪球's `SH600519` on extract.
    @State private var code: String = "600519"
    @State private var result: XueqiuProbe.ProbeResult?
    @State private var running = false

    var body: some View {
        HSplitView {
            // Left: the visible login browser. The user signs in here once.
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("雪球 登录 (visible WebView)")
                        .font(.headline)
                    Spacer()
                    Button("重新加载") { probe.reloadLogin() }
                        .controlSize(.small)
                }
                .padding(10)

                WebView(probe.loginPage)
                    .frame(minWidth: 380, minHeight: 400)
            }

            // Right: the linchpin explainer + controls + result.
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
            .frame(minWidth: 360)
        }
        .frame(minWidth: 820, minHeight: 560)
        .navigationTitle("雪球 BYO-Cookie Probe (DEV)")
    }

    // MARK: - Pieces

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("两个验证点 (linchpins)")
                .font(.title3.bold())
            Label {
                Text("**A — 跨 store cookie 可见性.** 无头 `WebPage` 能否看到可见登录 `WebView` 写入同一命名 `WKWebsiteDataStore` 的登录 cookie? 看结果里的 `已登录?`：true = 共享成功。")
            } icon: { Image(systemName: "key.fill") }
            Label {
                Text("**B — 无头 SPA 渲染.** 从不上屏的无头 `WebPage` 能否真正跑完雪球的 JS 并渲染出讨论文本? 看结果里的文本样本非空即成立。")
            } icon: { Image(systemName: "doc.text.magnifyingglass") }

            Text("用法：先在左侧登录雪球一次，再点下面的「提取讨论」。两者都用同一个固定 store UUID，所以登录态会被无头页继承。诊断日志带 `[XueqiuProbe]` 前缀，可在 Console.app 查看。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("A股代码")
                TextField("600519", text: $code)
                    .frame(width: 120)
                    .textFieldStyle(.roundedBorder)
                Text("→ \(XueqiuProbe.xueqiuSymbol(forAShareCode: code))")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }

            Button {
                runExtract()
            } label: {
                if running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("提取中…")
                    }
                } else {
                    Text("提取讨论 (headless)")
                }
            }
            .disabled(running || code.trimmingCharacters(in: .whitespaces).isEmpty)
            .buttonStyle(.borderedProminent)
        }
    }

    private func resultCard(_ r: XueqiuProbe.ProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("结果")
                .font(.headline)

            row("已登录? (A)", loggedInLabel(r.loggedIn))
            row("导航结果", r.navigation)
            if let url = r.finalURL { row("最终 URL", url) }
            row("文本长度 (B)", "\(r.textLength) 字符")
            if let err = r.error {
                row("错误", err, tint: .red)
            }

            if !r.textSample.isEmpty {
                Text("文本样本")
                    .font(.subheadline.bold())
                    .padding(.top, 4)
                Text(r.textSample)
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
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.callout)
                .foregroundStyle(tint)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func loggedInLabel(_ value: Bool?) -> String {
        switch value {
        case .some(true):  return "✓ 已登录 (cookie 已共享)"
        case .some(false): return "✗ 未登录 (检测到登录墙)"
        case .none:        return "? 无法判断"
        }
    }

    // MARK: - Actions

    private func runExtract() {
        let symbol = XueqiuProbe.xueqiuSymbol(forAShareCode: code)
        running = true
        result = nil
        Task {
            let r = await probe.extractDiscussion(symbol: symbol)
            await MainActor.run {
                self.result = r
                self.running = false
            }
        }
    }
}
