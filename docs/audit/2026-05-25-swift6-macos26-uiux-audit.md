# Wick — Swift 6 / macOS 26 / UI-UX 审计

**日期：** 2026-05-25
**范围：** `Wick/` 主 app target（不含 `TradingFloor` / `CandleKit` / `WickServer` 包内部实现）
**Swift 版本：** 6.0  ·  **部署目标：** macOS 26.0
**审计者：** Claude (Opus 4.7)

---

## 概要

整体现代化做得相当不错：

- `@Observable` + `@State` / `@Bindable` 全套到位，无 `@StateObject` / `@ObservedObject` / `@Published` 残留
- `@MainActor` 对所有 store 都做了显式标注
- macOS 26 部署目标，Liquid Glass API（`.glassEffect`, `GlassEffectContainer`, `glassEffectID`, `matchedGeometryEffect`）正确使用
- Swift Package 管理整洁（CandleKit / TradingFloor / WickServer 三个独立包）
- BYO + Server 双通道、Keychain 隔离每个 provider 的 key

下文按"现代并发"、"macOS 26 API"、"UI/UX"三个维度列出还能更进一步的地方。

---

## 一、Swift 6 / 现代并发 与 Observation 问题

### 1. `DispatchQueue.main.async` 残留
**位置：** `Wick/Views/WickerView.swift:650` — `scrollToBottom(_:)`

```swift
private func scrollToBottom(_ proxy: ScrollViewProxy) {
    DispatchQueue.main.async {
        withAnimation(.easeOut(duration: 0.18)) { ... }
    }
}
```

整个 View 已经是 `@MainActor`。应改为 `Task { @MainActor in ... }` 或直接去掉 async（依赖 `.onChange` 的下一轮 runloop 已经够了）。这是项目里唯一一处 GCD 调用，破坏了一致性。

### 2. Combine 的 `Timer.publish` 仍在用
**位置：** `Wick/Views/WickerView.swift:1054` — `TypingIndicator`

```swift
private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()
...
.onReceive(timer) { _ in phase = (phase + 1) % 3 }
```

macOS 26 的写法应该是 `TimelineView(.periodic(from: .now, by: 0.35))` 或者给三个点加 `.symbolEffect(.pulse, options: .repeat(.continuous))` / `phaseAnimator`。Combine 是 CLAUDE.md 自己标明要避免的（"prefer Swift's async and await versions of APIs"）。

### 3. `NSRegularExpression` vs 现代 `Regex`
**位置：** `Wick/Views/WickerView.swift:888` — `mentionedTickers`

Swift 5.7+ 应直接：
```swift
let pattern = /\$?[A-Z][A-Z.]{0,4}\b/
for match in text.matches(of: pattern) { ... }
```
更安全、更快、编译期校验。

### 4. `MainActor.run` 的过度使用
**位置：** `WickerView.swift:469/479/823/833`、`SettingsView.swift:505`

包含它们的 `Task { ... }` 改写成 `Task { @MainActor in ... }` 即可避免显式 `MainActor.run` hop。

### 5. `.onChange` 雪崩
**位置：** `Wick/Views/DetailView.swift:121-157`

一共 6 个 `.onChange`，部分相邻 onChange 互相耦合（chartScale 变化和 store.source 变化各跑一遍 `ChartTabState.apply`）。Swift 6 / iOS 17 之后更地道的是 `.task(id:)`，一并把"取消上一次"也包了。

### 6. Swift 6.2 的 `defaultIsolation = MainActor`
所有 `Wick/Data/*` 都手动写了 `@MainActor`。Swift 6.2 引入了 module-level `defaultIsolation: MainActor` 编译开关。Package.swift / xcconfig 加：

```swift
swiftSettings: [.defaultIsolation(MainActor.self)]
```

能把几十个 `@MainActor` 注解一次性删除。

### 7. 强制解包 URL
**位置：** `Wick/Views/WickerView.swift:1137`

```swift
?? URL(string: ProviderKind.anthropic.defaultBaseURL)!
```

应改成 `URL(static:)`（macOS 13+）或把 `defaultBaseURL` 直接做成 `URL` 类型。

### 8. Combine 依赖链
和上面 #2 配对：删掉 `Timer.publish` 能让整个 app 的 Combine import 干净（grep 没看到其他用例，等于零成本去 Combine 化）。

---

## 二、macOS 26 / Liquid Glass / Tahoe 用法问题

### 1. 自建搜索框替代 `.searchable(placement: .sidebar)`
**位置：** `Wick/Views/SidebarView.swift:80-99`

注释说"across NavigationSplitView quirks where `.searchable` placement sometimes ends up in the wrong column" — **这是 Xcode 16 SDK 的老 bug，Xcode 26 / macOS 26 已经修了**（Apple 文档：`SearchFieldPlacement.sidebar` "search field appears as a sticky header in the sidebar, attached to the toolbar"）。改回：

```swift
.searchable(text: $searchQuery, placement: .sidebar, prompt: "Stocks")
```

得到：
- 原生 sticky 头吸附到 toolbar
- ⌘F 自动 focus
- VoiceOver 完整支持
- 自动遵循 sidebar 的 Liquid Glass 表面

### 2. `.windowStyle(.hiddenTitleBar)` 让你放弃了系统 toolbar 的"自动 Liquid Glass"
**位置：** `Wick/App/WickApp.swift:64`

macOS 26 的 unified toolbar 在滚动时会自动用 Liquid Glass 折叠，自适应内容。手动隐藏后你不得不在 `DetailView.header` 里重做 toolbar 内容（tab picker + Indicators 按钮），而且 `.ignoresSafeArea(.container, edges: .top)` 是补丁式的修复（注释自己也承认）。

**建议：** 用 `.toolbar { ToolbarItemGroup { ... } }` 把 picker 放进真正的 toolbar，享受系统 Liquid Glass 与滚动适配；少 ~38pt 不值得放弃这些。

### 3. 旧 Material API 残留
**位置：** `Wick/Views/WickerView.swift:1046` — `TickerMentionChip`

用了 `.background(.regularMaterial, in: Capsule())`。整个项目其他地方都是 `glassEffect`，唯独这里不一致。应改成 `.glassEffect(.regular, in: Capsule())`。

### 4. 硬编码灰阶背景
**位置：** `Wick/Views/DetailView.swift:329-377`

`Color(white: 0.075)` / `Color(white: 0.97)` 强行画背景，覆盖了系统的自适应 canvas。macOS 26 推荐让 SwiftUI 管理底层 canvas，自定义只调 tint。这些硬编码颜色在高对比度模式 / 强调色变化时不会跟随。

### 5. `Settings { TabView { ... } }`
仍然可用，但 macOS 26 的现代写法是 `Window("Settings", id: "settings")` + `SettingsLink`，配合自定义布局。优先级低，但可考虑迁移。

### 6. 缺少 `.symbolEffect` 的地方
**位置：** `Wick/Views/SidebarView.swift` Wicker 行的 `sparkles` 图标

既然你强调"Wicker is alive and listening"，可以给那颗 sparkles 加：
```swift
.symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
```

比对整个浮动 composer 长亮发光优雅得多。

### 7. `.onChange(of:)` 的 2-参数闭包
**位置：** `SidebarView.swift:71`、`DetailView.swift:121-157`

部分写 `(_, _) in` — 说明不需要新旧值。可以直接用 `.onChange(of: x) { ... }` 无参版本（Swift 6 推荐），更简洁。

---

## 三、UI / UX 问题（按严重程度排序）

### A. 严重：伪造的 Pre-Market 价格 🚨
**位置：** `Wick/Views/DetailView.swift:262-269`

```swift
private func preMarketOffset(symbol: String, last: Double) -> Double {
    let hash = symbol.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    let signed = (hash % 7) - 3
    return last * Double(signed) / 1000.0
}
```

**这是真实金额展示中的虚构数据**。用户看到"Pre-Market $284.74 +0.85"会当真。即使有 `sourceBadge`，价格本身没有任何 demo 标签。

**处理：** 要么删除这一列，要么明确标注 "Synthetic" 并改成灰阶；股票 app 在金钱数字上虚构是 UX 红线。

### B. 严重：HoldingsStore 在首次启动塞入 16 笔虚假交易 🚨
**位置：** `Wick/Data/Holdings.swift:71-137`

默认注入 AAPL/MSFT/NVDA/TSLA/GOOGL/META 的 buy/sell ledger。Portfolio 页面会显示一份用户从未输入的持仓。

**处理：**
- 默认空仓 + 首次启动弹一个 "Use sample portfolio?" 引导
- 或者用 SF Symbols + 灰色 "Sample" 标记每一行

现状下，"我的持仓"语义被颠覆。

### C. 严重：浮动 Wicker composer 始终发光、永远在场
**位置：** `Wick/Views/FloatingWickerComposer.swift:46-76` + `Wick/Views/WickerView.swift:704-714`

两层 "always-on 0.85 强度" glow 叠加 + 永久占据右下角 ~340×80pt：
- 视觉嗡鸣（持续动画在生产力软件里很疲劳）
- 提交后强制跳走当前路由到 `.wicker` — 用户在看图表/新闻时被弹出
- 每次都开新 session，没法在非 Wicker 路由继续已有对话
- 没有最小化/隐藏开关

**建议：** 默认折叠成单按钮 "✨"，点击展开 composer；glow 只在 `pending` 时亮；提交后保留当前路由，在右下角显示一个浮动的"答复已就绪 ↗"小气泡，用户点击才跳转。

### D. 重复入口：每个 ticker 的 AI tab + 全局 Floating Wicker
**位置：** `Wick/Views/DetailView.swift` `.ai` tab + `ContentView.swift:94-104`

两个并行的 AI 入口让用户困惑。建议：彻底删除 AI tab，浮动 composer 是唯一入口；或反之。

### E. 首屏建议提示不像可点
**位置：** `Wick/Views/WickerView.swift:561-588`

hero 上 4 个 prompt 用 `·` 分隔、字体 11pt、`.secondary` 颜色、`buttonStyle(.plain)`。完全看不出可点。Apple 的 suggestion chips 标准做法是带细边框的 capsule + 弱阴影。当前这一行很可能被用户当作版权信息略过。

### F. 浮动 composer 遮挡 Detail / Portfolio 内容
**位置：** `Wick/App/ContentView.swift:94-104`

用 `.overlay(alignment: .bottomTrailing)` 直接覆盖底部。图表/持仓表的最后一行经常被遮。

**正确做法：** `.safeAreaInset(edge: .bottom) { ... }` — 内容会自动收缩出空间，不再被遮挡。

### G. Sidebar 三种"非股票"路由没有分组 header
**位置：** `Wick/Views/SidebarView.swift:33-46`

Portfolio / Wicker / Market 三行直接放在第一个 `Section {}`（无 header），紧接着的股票 section 有 header。视觉上股票区域被"封顶"，但上面三行像浮在半空。

**建议：** 第一组加 `header: { Text("OVERVIEW") }`，或用 `.listSectionSeparator(.hidden)` + spacing 控制。

### H. Sparkline 在 240pt 阈值"啪"地消失
**位置：** `Wick/Views/SidebarView.swift:101-108`

离散 boolean 切换。用户拖拽分隔条到边界会看到 sparkline 闪烁。改成宽度 → 透明度的连续映射（240→1.0, 200→0.0）会顺滑很多。

### I. Tab picker 在 header 里 280pt 固定宽
**位置：** `Wick/Views/DetailView.swift:207-214`

`.frame(width: 280)` 锁死。在窄窗口下挤压 ticker name；在宽窗口下右侧有大段空白。考虑 `.fixedSize()` 让 picker 自适应。

### J. `ChartIndicatorConfig` "全局共用" 但每次 ticker 切换 `.id(ticker.id)` 重建 DetailView
**位置：** `Wick/App/ContentView.swift:90`

这会丢失 chart 的 zoom/pan 状态、coordinator 状态、当前 `chartScale2`、`range`、`indicatorSheetShown` 等所有 `@State`。用户在 NVDA 放大到 5 分钟级别，点 AAPL 再回来——重置回 1 月。

**建议：** `.id()` rebuild 是 nuclear option，改成显式 `onChange(of: ticker.id)` 重置必要的部分。

### K. 三个 didSet 都触发 `agentRuntime.reconfigure(with:)`
**位置：** `Wick/App/WickApp.swift:54-62`

用户在 Settings 里粘贴 fmpKey / finnhubKey / fredKey 三个 key 时，会触发三次重新构建整个 data chain。`.task(id: settings.dataKeysFingerprint)` debounce 一下更聪明。

### L. SecureField 失焦后立刻 keychain 写入
**位置：** `Wick/Data/AgentSettings.swift:60-66`

每个字符都触发 keychain `Save`。Keychain 写入是 sync IO call，键入长 key 时会卡 UI。debounce 500ms 或在 `.onSubmit` 写入即可。

### M. `Settings` 的 Form 宽度不统一
**位置：** `Wick/Views/SettingsView.swift`

所有 6 个 tab 的 Form 宽度都是 460/540/560 三种不同值——用户切 tab 时窗口在动。统一成一个值（比如 520）会让 Settings 安静下来。

### N. 浮动 composer 的提交不显示状态
**位置：** `Wick/Views/FloatingWickerComposer.swift:113-121`

`submit()` 之后立刻清空 draft + 跳路由。在低性能机器上 route 切换前的瞬间用户看不到任何"已发送"反馈，可能重复点击。给 send 按钮加一个 0.2s 的 spinner 或弹簧动画。

### O. `MarketView` 是占位 ("Coming soon")
**位置：** `Wick/Views/MarketView.swift`

占用 sidebar 顶部 slot，但点进去只有 "Coming soon" 卡片。在 ship 之前隐藏这个路由，或先放一个最小可用版本（已有 `TreemapView`，sector heatmap 应该 1 小时内能塞进去）。

### P. `WickerView` rename alert binding
**位置：** `Wick/Views/WickerView.swift:56-65`

用 `Binding(get: { renamingSessionID != nil }, set: ...)`。macOS 26 推荐用 `.alert(_:isPresented:presenting:actions:message:)` 的 `presenting:` 版本：

```swift
.alert("Rename", isPresented: $renaming, presenting: renamingSessionID) { id in ... }
```

更清晰，避免 manual binding。

---

## 修复优先级建议

| 优先级 | 项目 | 类别 |
|---|---|---|
| **P0 立刻** | A. 伪造 Pre-Market 价格 | UX 红线 |
| **P0 立刻** | B. 自动注入虚假持仓 | UX 红线 |
| **P1 短期** | 1. `.searchable(.sidebar)` 替代手撸搜索框 | macOS 26 |
| **P1 短期** | 3. 删 `DispatchQueue.main.async` | Swift 6 |
| **P1 短期** | C. composer always-on glow 改成 pending-only | UX |
| **P2 中期** | 2. `Timer.publish` → `TimelineView` | Swift 6 |
| **P2 中期** | F. composer 用 `safeAreaInset` | UX |
| **P2 中期** | D. AI tab 与浮动 composer 二选一 | UX |
| **P2 中期** | J. 去掉 `.id(ticker.id)` | UX |
| **P3 长期** | 6. `defaultIsolation = MainActor` | Swift 6 |
| **P3 长期** | 2(macOS). 回归原生 toolbar | macOS 26 |
| **P3 长期** | M. Settings 统一宽度 | UX |

---

## 四、Xcode 项目目录结构

### 现状摸底

```
/Users/baixianger/personal/
├── CandleKit/                 ← 同级仓库（out-of-tree 包）
└── Wick/                      ← 本仓库根
    ├── Wick.xcodeproj/        ← xcodegen 生成，.gitignore 忽略
    ├── project.yml            ← xcodegen spec
    ├── Wick/                  ← app target 源码根（与仓库同名，嵌套）
    │   ├── App/               (3 files)
    │   ├── Data/              (17 files — 混合 store / model / infra)
    │   ├── Design/            (3 files — 仅视觉效果，名不副实)
    │   ├── Resources/         (Assets / Info.plist / entitlements)
    │   └── Views/             (11 files — sheet / tab / main 没分层)
    ├── TradingFloor/          ← in-tree SPM package
    ├── WickServer/            ← in-tree SPM package
    ├── docs/                  ← 文档（本文所在）
    ├── notes/                 ← 单文件，与 docs 语义重叠
    └── scripts/               ← generate.sh
```

### 问题清单

#### a. SPM 包位置策略不一致 ⚠️
**位置：** `project.yml` packages 段

```yaml
packages:
  CandleKit:
    path: ../CandleKit          # out-of-tree（同级仓库）
  TradingFloor:
    path: TradingFloor          # in-tree（子目录）
```

而 `WickServer/` 又是另一个 in-tree SPM 包（虽然不挂在 app 上，但物理位置混在仓库里）。三个本地包用两种策略。

**后果：**
- 新协作者 clone `Wick` 后 `xcodegen generate` 会失败（找不到 `../CandleKit`），必须先 clone 同级的 CandleKit 仓库
- README.md 仅 1KB，没有写"先 clone CandleKit"的引导
- IDE 跨仓库跳转 vs in-tree 跳转体验不同

**建议（任选其一）：**
- **方案 A（推荐）：把 CandleKit 作为 git submodule** 放到 `Wick/Packages/CandleKit`，`project.yml` 改成 `path: Packages/CandleKit`，三个包统一为 in-tree。submodule 保留独立提交历史。
- **方案 B：保持 out-of-tree 但显式声明** — README 里加 "Prerequisites: clone CandleKit alongside this repo"，并在 `scripts/generate.sh` 里做存在性检查。

#### b. `Wick/Wick/` 嵌套命名
仓库 = 子目录 = target，路径写起来繁琐：`Wick/Wick/App/WickApp.swift`。xcodegen 项目常见现象，但可改善。

**建议：** 把 source root 改名为 `Wick/Sources/`（或 `App/`），`project.yml` target 的 `sources` 路径同步更新。会更接近 SPM-native 风格，跟 `TradingFloor/Sources/TradingFloor/` 一致。

#### c. `Wick/Data/` 17 文件扁平混合
当前同时塞了 4 个职责：

| 类别 | 文件 |
|---|---|
| Stores (state holders) | `HoldingsStore`, `ChatStore`, `WatchlistStore`, `ReportHistoryStore`, `LiveDataStore` |
| Settings / Config | `AgentSettings`, `Provider`, `ModelDiscovery`, `AgentRuntime`, `DeskRunner` |
| Domain models | `Ticker`, `News`, `Holding`(in Holdings.swift), `ChartIndicatorConfig` |
| Infra / Adapters | `Keychain`, `ServerReportClient`, `SessionTitler`, `WickMarketDataProvider` |

**建议拆分：**
```
Wick/
├── Models/         ← Ticker, News, Holding 等纯数据
├── Stores/         ← 5 个 @Observable store
├── Services/       ← Keychain, ServerReportClient, SessionTitler, WickMarketDataProvider
└── Config/         ← AgentSettings, Provider, ModelDiscovery, AgentRuntime, DeskRunner
```
扁平 17 文件夹在 17 行已经超过一屏，Xcode navigator 滚动找文件成本高。

#### d. `Wick/Views/` 11 文件不分层
`Tabs.swift`（估计 700+ 行，含多个 sub-view）、`SettingsView.swift`、`HoldingEditorSheet.swift`、`IndicatorManagerView.swift`、`DetailView.swift`、`PortfolioView.swift`、`WickerView.swift`、`SidebarView.swift`、`MarketView.swift`、`FloatingWickerComposer.swift`、`OverviewRange.swift` 都在一起。

**建议拆分：**
```
Wick/
└── Views/
    ├── Detail/        ← DetailView.swift, Tabs.swift(拆分), OverviewRange.swift
    ├── Sidebar/       ← SidebarView.swift
    ├── Wicker/        ← WickerView.swift, FloatingWickerComposer.swift
    ├── Portfolio/     ← PortfolioView.swift, HoldingEditorSheet.swift
    ├── Market/        ← MarketView.swift
    ├── Settings/      ← SettingsView.swift（拆成 6 个文件，对应 6 个 tab）
    └── Indicators/    ← IndicatorManagerView.swift
```
`Tabs.swift` 单文件多 view 也建议拆开 —— 跟 `DetailView` 一起放 `Detail/Tabs/` 目录。

#### e. `Wick/Design/` 命名不副实
只放 `FlatPicker`, `IntelligenceGlow`, `LiquidGlass` —— 都是**视觉组件 / 效果**，不是"设计系统"。

**建议改名：** `Effects/` 或 `Components/`。如果未来想做真正的设计系统（Token / Spacing / Typography），再用 `DesignSystem/` 这个名字。

#### f. `Wick/App/SidebarRoute.swift` 应该分离
`SidebarRoute` 是 routing enum（domain model），不是 app shell。`App/` 应该只有 `WickApp.swift` + `ContentView.swift`。

**建议：** 挪到 `Models/Navigation/` 或者 `Views/Sidebar/SidebarRoute.swift`。

#### g. `docs/` 与 `notes/` 重叠
`notes/` 里只有 1 个 HTML 文件（`agent-workflow-references.html`）。等于平行了两个文档目录。

**建议：** 合并到 `docs/`：
```
docs/
├── audit/                  ← 审计报告（本文）
├── references/             ← 外部资料（agent-workflow-references.html 进这里）
└── architecture/           ← 未来的 ADR / 架构图
```
然后删 `notes/`。

#### h. `Wick.xcodeproj` 被 gitignore — 但需要文档说明工作流
`.gitignore` 第 22 行：

```
# Generated Xcode project (regenerate via `xcodegen generate`)
Wick.xcodeproj
```

`scripts/generate.sh` 里应该是 `xcodegen generate` 包装。新协作者从零开始：

1. clone Wick + clone CandleKit (跨仓库 sibling)
2. `brew install xcodegen`
3. 运行 `scripts/generate.sh`
4. 打开 Wick.xcodeproj

但 README.md 1KB 没写这个流程 —— 没有 onboarding。

**建议：** 在 README.md 里加 "Getting Started" 段。或者用 GitHub Actions 在 CI 里验证 `xcodegen generate && xcodebuild` 跑得起来。

#### i. 缺少 app target 的测试目录
`TradingFloor/Tests/`、`CandleKit/Tests/` 都有完整单测，但 `Wick/` app target 本身没有 `Tests/`。即使 SwiftUI 单测不容易，至少：
- store 层（`HoldingsStore.positions()`、`WatchlistStore.filter(...)`、`SessionGroup.build(...)`）应该有单测
- regex / parsing（`mentionedTickers`）应该有单测

**建议：** 加 `WickTests/` 目录，在 `project.yml` 里挂上 unit-test target。

#### j. WickServer 的私有 markdown 进了仓库
`WickServer/fmp.md` 和 `WickServer/finnhub.md` 被 `.gitignore` 排除（line 41-42），但物理存在 —— 这意味着它们是私有笔记，靠 gitignore 隐藏。

**建议：**
- 如果是临时调研笔记，挪到 `docs/research/`（注意脱敏）
- 如果是 server 的 API key 配置说明，应该挪进 `WickServer/docs/` 并入仓
- 不要靠 gitignore 隐藏，命名上就分开（比如 `*.private.md`）

### 推荐的目标结构

```
Wick/                              ← 仓库根
├── README.md                       ← 扩成 ~5KB 含 Getting Started
├── project.yml                     ← xcodegen
├── scripts/
│   └── generate.sh
├── docs/
│   ├── audit/
│   ├── references/                 ← 收编 notes/
│   └── architecture/
├── Packages/                       ← 统一 in-tree 本地包
│   ├── CandleKit/                  ← 改成 git submodule
│   ├── TradingFloor/               ← 从 Wick/TradingFloor 挪入
│   └── WickServer/                 ← 从 Wick/WickServer 挪入
├── Sources/                        ← 取代嵌套的 Wick/Wick/
│   ├── App/                        ← 只剩 WickApp + ContentView
│   ├── Models/                     ← Ticker, News, Holding, SidebarRoute
│   ├── Stores/                     ← 5 个 @Observable
│   ├── Services/                   ← Keychain, ServerReportClient...
│   ├── Config/                     ← AgentSettings, Provider, AgentRuntime...
│   ├── Views/
│   │   ├── Detail/
│   │   ├── Sidebar/
│   │   ├── Wicker/
│   │   ├── Portfolio/
│   │   ├── Market/
│   │   ├── Settings/
│   │   └── Indicators/
│   ├── Effects/                    ← 原 Design/
│   └── Resources/
└── Tests/
    └── WickTests/
```

### 结构层面的修复优先级

| 优先级 | 项 |
|---|---|
| **P1 短期** | (a) CandleKit 改 submodule + Packages/ 统一；(h) README.md 扩 Getting Started |
| **P2 中期** | (c) `Data/` 四向拆分；(d) `Views/` 按 feature 分子目录；(g) 合并 notes 进 docs |
| **P3 长期** | (b) 去掉 `Wick/Wick/` 嵌套；(e) `Design/` 改名；(i) 加 WickTests target |

---

## 附：审计方法

- 静态阅读 `Wick/App/*.swift`、`Wick/Data/*.swift`、`Wick/Views/*.swift`、`Wick/Design/*.swift` 全量
- `Wick.xcodeproj/project.pbxproj` 确认 `SWIFT_VERSION = 6.0` / `MACOSX_DEPLOYMENT_TARGET = 26.0`
- TradingFloor / WickServer `Package.swift` 确认 `swift-tools-version: 6.0`
- Grep `@StateObject|@ObservedObject|@EnvironmentObject|ObservableObject|Combine|@Published` → 0 命中（已现代化）
- Grep `DispatchQueue|withCheckedContinuation|@unchecked|nonisolated\(unsafe\)|Sendable` → 仅 7 处，均已具名审查
- Grep `\.toolbar|NavigationStack|NavigationSplitView|hiddenTitleBar|windowStyle|GeometryReader|glassEffect` → 摸清 chrome 与 Liquid Glass 用法
- 对照 Apple Developer Documentation（`SearchFieldPlacement.sidebar`、`NavigationSplitView`）确认 macOS 26 推荐路径
- 文件系统层面：`ls`/`find` 摸清 `Wick.xcodeproj`、`project.yml`、`.gitignore`、`Packages/` 实际存在状态；确认 CandleKit 是 out-of-tree 同级仓库（`/Users/baixianger/personal/CandleKit`）
