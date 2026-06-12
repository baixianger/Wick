import SwiftUI
import TradingFloor
import UniformTypeIdentifiers

/// Native macOS Settings pane. Renders as the modern two-column
/// sidebar Apple's System Settings (macOS 13+) and pro apps use: a
/// category `List` on the LEFT, the selected category's `Form` on the
/// RIGHT — replacing the older icon-above-label tab strip.
///
/// Structure:
///   - `NavigationSplitView` with a `List(selection:)` sidebar over
///     `SettingsCategory` (one case per former tab — same titles +
///     SF Symbol icons) in `.sidebar` style. Selection drives a
///     `switch` in the detail pane that hosts the EXISTING per-tab
///     `View` structs verbatim (`ProviderTab`, `DataSourcesTab`, …).
///   - Each tab is a `Form` with `.formStyle(.grouped)` so its
///     sections render as inset rounded-rectangle cards with bold
///     headers — the System Settings look. A large-title category
///     header (`SettingsDetailHeader`) crowns the pane via a top
///     safe-area inset; high-value rows adopt the icon-tile + title +
///     subtitle + trailing-control cell (`SettingsRow`). The per-tab
///     `.frame(width:)` / `.fixedSize` that TabView used for window
///     sizing are gone — the detail pane fills the right column and
///     the split-view root carries one fixed window size instead.
///   - No `NavigationStack`, no Done button — the close-window red
///     dot dismisses, matching System Settings.
struct SettingsView: View {
    @Bindable var settings: AgentSettings

    /// Default-selects Provider so the window never opens to an empty
    /// detail pane. Persisted only for the session — Settings is modal
    /// enough that re-opening to Provider each time is the expected
    /// macOS behaviour.
    @State private var selection: SettingsCategory = .provider

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { category in
                Label(category.title, systemImage: category.systemImage)
                    // A consistent symbol frame keeps the leading icons
                    // optically aligned (some SF Symbols are wider than
                    // others), so the labels line up like System Settings.
                    .labelStyle(SidebarLabelStyle())
                    .tag(category)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
            // System Settings has NO collapse chevron and begins its rows
            // flush under the traffic-light row — drop the toggle so the
            // sidebar reads as a single calm inset panel.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // Use the NATIVE navigation title, not a custom header. macOS
            // already reserves a title-bar strip atop the split-view detail
            // pane (the sidebar side fills it with the collapse toggle); a
            // custom `safeAreaInset` header sat BELOW that strip, leaving the
            // native bar empty — the blank band at the top. `navigationTitle`
            // drops the title INTO that bar, filling it, matching System
            // Settings' big-title look with no empty space above it.
            detail(for: selection)
                .navigationTitle(selection.title)
                // BREATHING ROOM: the grouped `Form` is a scroll view, so its
                // first Section card otherwise butts straight up against the
                // native large-title bar — cramped. A top scroll-content margin
                // pushes the first card down to System Settings' airy margin
                // WITHOUT leaving an empty band (the title bar still fills the
                // very top). Applied here on the shared detail content so it's
                // identical across all 7 category tabs in one place.
                .contentMargins(.top, 18, for: .scrollContent)
        }
        // RESIZABLE: a min keeps the first card un-clipped + an ideal sets
        // the opening size, but `maxWidth/Height: .infinity` lets the user
        // drag the window larger (System Settings is resizable). Without the
        // `.infinity` maxes the ideal pinned the window and the resize
        // handles did nothing.
        .frame(minWidth: 720, idealWidth: 860, maxWidth: .infinity,
               minHeight: 540, idealHeight: 680, maxHeight: .infinity)
    }

    /// Hosts the existing per-tab view for `category` as detail content.
    /// Each struct already wraps itself in a `Form`, so it fills the
    /// right pane directly.
    @ViewBuilder
    private func detail(for category: SettingsCategory) -> some View {
        switch category {
        case .provider:  ProviderTab(settings: settings)
        case .data:      DataSourcesTab(settings: settings)
        case .workflow:  WorkflowTab(settings: settings)
        case .freeAgent: FreeAgentTab(settings: settings)
        case .skills:    SkillsTab(settings: settings)
        case .display:   AppearanceTab(settings: settings)
        case .mcp:       MCPTab()
        }
    }
}

// MARK: - Shared chrome

/// Sidebar `Label` style with a fixed-width symbol slot so every row's
/// title starts at the same x regardless of glyph width — the calm,
/// aligned look of the System Settings sidebar. Adds vertical padding so
/// rows breathe at ~30–32pt like the reference; the selection pill (a
/// solid blue rounded bar, white icon + text) is rendered natively by
/// `.listStyle(.sidebar)`. Unselected icons read `.secondary` so they
/// recede next to the white-on-blue selected row.
private struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon
                .font(.system(size: 15))
                .frame(width: 22, alignment: .center)
            configuration.title
                .font(.system(size: 13))
        }
        .padding(.vertical, 3)
    }
}

/// Reusable "icon-tile + title + subtitle + trailing control" row — the
/// rich System Settings cell. A rounded `tint`-filled tile carries the
/// SF Symbol on the leading edge, a `title` + secondary `subtitle`
/// stack fills the middle, and any `control` (toggle, field, button)
/// pins to the trailing edge. Used for the highest-value rows; plain
/// `Toggle`/`TextField` rows stay as-is so the density matches the ref.
private struct SettingsRow<Control: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        LabeledContent {
            control()
        } label: {
            HStack(spacing: 12) {
                // System Settings icon tile: ~29pt rounded-rect, tint
                // gradient fill, optically-centred glyph. The continuous
                // corner + the slightly-larger square reads as the
                // reference's "app icon" leading tile rather than a chip.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 29, height: 29)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13))
                    if let subtitle {
                        Text(.init(subtitle))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // Two-line rows ride tall (~50pt) in System Settings; a little
            // vertical padding gives that airy cell height without forcing
            // a fixed frame that would clip dynamic-type.
            .padding(.vertical, 3)
        }
    }
}

// MARK: - Sidebar categories

/// One case per former Settings tab. Carries the SAME title + SF Symbol
/// the `.tabItem` Label used, so the sidebar reads identically to the
/// old tab strip. `CaseIterable` order is the sidebar order (Provider
/// first, matching the default selection).
private enum SettingsCategory: String, CaseIterable, Identifiable {
    case provider, data, workflow, freeAgent, skills, display, mcp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .provider:  return "Provider"
        case .data:      return "Data"
        case .workflow:  return "Workflow"
        case .freeAgent: return "Free Agent"
        case .skills:    return "Skills"
        case .display:   return "Display"
        case .mcp:       return "MCP"
        }
    }

    var systemImage: String {
        switch self {
        case .provider:  return "key.fill"
        case .data:      return "chart.line.uptrend.xyaxis"
        case .workflow:  return "list.bullet.indent"
        case .freeAgent: return "bubble.left.and.bubble.right"
        case .skills:    return "book.closed"
        case .display:   return "paintpalette"
        case .mcp:       return "puzzlepiece.extension"
        }
    }
}

// MARK: - MCP tab

/// Shows how to wire the bundled `wick-mcp` helper into Claude Code /
/// Codex CLI / any MCP client. The helper ships inside the .app bundle
/// at `/Applications/Wick.app/Contents/MacOS/wick-mcp`, runs as its own
/// sandboxed subprocess each time the client connects, and reads
/// holdings / watchlist out of the App Group container Wick.app writes
/// to. The user does NOT need to keep Wick open — the helper is
/// invoked on demand by their MCP client.
private struct MCPTab: View {
    @State private var testStatus: MCPTestStatus = .idle
    @State private var isTesting = false

    private var helperPath: String { Self.resolveHelperPath() }

    /// JSON snippet the user pastes into `~/.claude.json` (or the Codex
    /// `mcp.json` equivalent). Built fresh from `helperPath` so it
    /// always points at the current install location.
    private var claudeCodeConfig: String {
        """
        {
          "mcpServers": {
            "wick": {
              "type": "stdio",
              "command": "\(helperPath)"
            }
          }
        }
        """
    }

    var body: some View {
        Form {
            Section("Helper") {
                // Rich status row: a green/orange icon-tile signals
                // whether the App Group bridge is live, with the
                // bundle/provisioning detail as the subtitle.
                SettingsRow(
                    systemImage: SharedStore.isAppGroupAvailable
                        ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    tint: SharedStore.isAppGroupAvailable ? .green : .orange,
                    title: "`wick-mcp` ships inside Wick.app",
                    subtitle: SharedStore.isAppGroupAvailable
                        ? "Sharing holdings + watchlist with helper (App Group active)"
                        : "App Group not provisioned — helper will see empty holdings"
                ) {
                    EmptyView()
                }
                Text(helperPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button {
                        Task { await runTest() }
                    } label: {
                        Label(isTesting ? "Testing…" : "Test connection",
                              systemImage: "bolt.horizontal.circle")
                    }
                    .disabled(isTesting)
                    Spacer()
                    testStatusBadge
                }
            }

            Section("Claude Code / Codex") {
                Text("Add this to `~/.claude.json` (Claude Code) or your Codex `mcp.json` — then the agent can call `wick.snapshot`, `wick.candles`, `wick.holdings`, `wick.watchlist`, `wick.portfolio`.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(claudeCodeConfig)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 160)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack {
                    Button {
                        copyToPasteboard(claudeCodeConfig)
                    } label: {
                        Label("Copy JSON snippet", systemImage: "doc.on.doc")
                    }
                    Button {
                        copyToPasteboard(helperPath)
                    } label: {
                        Label("Copy helper path", systemImage: "terminal")
                    }
                    Spacer()
                }
            }

            Section("Notes") {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Wick doesn't need to be running. The helper spawns on demand.",
                          systemImage: "power.circle")
                        .font(.system(size: 11))
                    Label("Helper is sandboxed: outbound HTTP + App Group only. No file-system, no listening sockets.",
                          systemImage: "lock.shield")
                        .font(.system(size: 11))
                    Label("Each invocation is short-lived — your MCP client kills it when it disconnects.",
                          systemImage: "hourglass")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Locate the helper relative to the current bundle. In a production
    /// install this is `/Applications/Wick.app/Contents/MacOS/wick-mcp`;
    /// during development xcodebuild drops the bundle in DerivedData and
    /// `Bundle.main.bundlePath` resolves there. Either way the absolute
    /// path is what the user needs.
    private static func resolveHelperPath() -> String {
        let bundle = Bundle.main.bundlePath
        return bundle + "/Contents/MacOS/wick-mcp"
    }

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    /// Visual badge next to the Test connection button. Renders the
    /// most recent test outcome until the user runs the test again.
    @ViewBuilder
    private var testStatusBadge: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .ok(let rttMillis, let toolCount):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("OK · \(toolCount) tools · \(rttMillis) ms")
                    .font(.caption.monospacedDigit())
            }
        case .failed(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
    }

    /// Spawn the bundled helper, perform the MCP handshake + tools/list
    /// round-trip, and surface the result. Best-effort: any exception
    /// surfaces as `.failed(message)` so the user sees what broke.
    private func runTest() async {
        await MainActor.run {
            isTesting = true
            testStatus = .testing
        }
        defer { Task { @MainActor in isTesting = false } }

        let path = helperPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            await MainActor.run { testStatus = .failed("Helper not found at \(path)") }
            return
        }

        let started = Date()
        let result = await Self.probeHelper(at: path)
        let rttMillis = Int(Date().timeIntervalSince(started) * 1000)

        await MainActor.run {
            switch result {
            case .success(let toolCount):
                testStatus = .ok(rttMillis: rttMillis, toolCount: toolCount)
            case .failure(let error):
                testStatus = .failed(error.localizedDescription)
            }
        }
    }

    /// Drive one MCP handshake against the binary at `path`. Returns
    /// the number of tools the helper advertises on success.
    private static func probeHelper(at path: String) async -> Result<Int, Error> {
        await Task.detached { () -> Result<Int, Error> in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                return .failure(error)
            }
            // Timeout watchdog. 8 s covers a worst-case cold-cache
            // App-Group + JSON-RPC handshake by a comfortable margin
            // while keeping the Settings UI responsive. If the
            // helper wedges (e.g. waiting on stdin after writing
            // all responses, or blocked on a sandbox prompt) the
            // probe surfaces a real error instead of spinning
            // "Testing…" forever.
            let timeoutTask = Task.detached {
                try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
                if process.isRunning { process.terminate() }
            }
            let initReq = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"settings-probe","version":"0"}}}"# + "\n"
            let initedNote = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n"
            let listReq = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"
            stdin.fileHandleForWriting.write(initReq.data(using: .utf8)!)
            stdin.fileHandleForWriting.write(initedNote.data(using: .utf8)!)
            stdin.fileHandleForWriting.write(listReq.data(using: .utf8)!)
            try? stdin.fileHandleForWriting.close()

            // Drain pipes on detached tasks BEFORE waitUntilExit so
            // the helper can write its full `tools/list` reply
            // without blocking on a full pipe buffer. (Same fix as
            // ClaudeCodeProvider.swift — both probes had the
            // identical deadlock pattern.)
            let outReader = Task.detached {
                stdout.fileHandleForReading.readDataToEndOfFile()
            }
            let errReader = Task.detached {
                stderr.fileHandleForReading.readDataToEndOfFile()
            }
            process.waitUntilExit()
            timeoutTask.cancel()
            let outDataValue = await outReader.value
            let errDataValue = await errReader.value
            guard process.terminationStatus == 0 else {
                let err = String(data: errDataValue, encoding: .utf8) ?? ""
                return .failure(NSError(
                    domain: "WickMCPProbe", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Helper exited \(process.terminationStatus): \(err)"]))
            }
            let data = outDataValue
            let lines = (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n")
            for line in lines {
                guard let raw = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      (obj["id"] as? Int) == 2,
                      let result = obj["result"] as? [String: Any],
                      let tools = result["tools"] as? [[String: Any]]
                else { continue }
                return .success(tools.count)
            }
            return .failure(NSError(
                domain: "WickMCPProbe", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No tools/list response in \(lines.count) frames"]))
        }.value
    }
}

private enum MCPTestStatus: Equatable {
    case idle
    case testing
    case ok(rttMillis: Int, toolCount: Int)
    case failed(String)
}

// MARK: - Data sources tab

/// BYO data keys: FMP / Finnhub / FRED. Mirrors the decorator chain
/// WickServer assembles for the server tier — see
/// `AgentRuntime.makeMarketDataProvider`. Hidden information when
/// providerKind == .server because the server has its own keys.
private struct DataSourcesTab: View {
    @Bindable var settings: AgentSettings

    /// Read-only catalog model — pure reference UI, nothing persisted.
    private struct DataSourceEntry: Identifiable {
        let id = UUID()
        let symbol: String
        let name: String        // e.g. "EastMoney 行情 & K线"
        let provides: String    // subtitle, e.g. "实时报价 · 日/周/月/分钟 K线"
        let access: DSAccess
        let status: DSStatus
    }

    private enum DSAccess {
        case free, freeKey, byo
        var label: String {
            switch self {
            case .free:    "免费"
            case .freeKey: "免费·需Key"
            case .byo:     "自带账号"
            }
        }
        var tint: Color {
            switch self {
            case .free:    .green
            case .freeKey: .orange
            case .byo:     .blue
            }
        }
    }

    private enum DSStatus {
        case active, planned
        var label: String { self == .active ? "已接入" : "计划中" }
        var tint: Color { self == .active ? .green : .secondary }
    }

    private enum DSMarket: String, CaseIterable, Identifiable {
        case cn = "A股 / 港股", us = "美股"
        var id: String { rawValue }
    }

    /// Which market's source list the segmented picker shows.
    @State private var market: DSMarket = .cn

    private static let cnSources: [DataSourceEntry] = [
        .init(symbol: "chart.xyaxis.line",                name: "EastMoney 行情 & K线", provides: "实时报价 · 日/周/月/分钟 K线",        access: .free, status: .active),
        .init(symbol: "dollarsign.circle",                name: "EastMoney 资金流",     provides: "主力/超大/大/中/小单净流入",       access: .free, status: .active),
        .init(symbol: "doc.text",                         name: "EastMoney F10 财务",   provides: "营收/净利/EPS/ROE/毛利率 等",      access: .free, status: .active),
        .init(symbol: "flame",                            name: "EastMoney 龙虎榜",     provides: "上榜原因 · 净买入 · 席位解读",     access: .free, status: .active),
        .init(symbol: "flame",                            name: "EastMoney 涨停板",     provides: "涨停池 · 连板 · 封单额",          access: .free, status: .active),
        .init(symbol: "bubble.left.and.bubble.right",     name: "雪球 讨论/情绪",       provides: "个股讨论 · 散户情绪",             access: .byo,  status: .active),
        .init(symbol: "dollarsign.circle",                name: "EastMoney 北向资金",   provides: "沪深港通 · 外资流向",             access: .free, status: .planned),
        .init(symbol: "building.columns",                 name: "HKEX 沽空",            provides: "港股卖空数据",                   access: .free, status: .planned),
        .init(symbol: "building.columns",                 name: "港交所 CCASS",         provides: "中央结算持股分布",               access: .free, status: .planned),
        .init(symbol: "chart.xyaxis.line",                name: "新浪 / 腾讯 报价",     provides: "A股实时报价(备份源)",            access: .free, status: .planned),
    ]

    private static let usSources: [DataSourceEntry] = [
        .init(symbol: "chart.xyaxis.line",                name: "Yahoo Finance",        provides: "行情 · K线 · 搜索",              access: .free,    status: .active),
        .init(symbol: "doc.text",                         name: "FMP",                  provides: "基本面 · 估值",                  access: .freeKey, status: .active),
        .init(symbol: "bubble.left.and.bubble.right",     name: "Finnhub",              provides: "新闻 · 情绪",                    access: .freeKey, status: .active),
        .init(symbol: "building.columns",                 name: "FRED",                 provides: "宏观:利率/CPI/非农/GDP",          access: .freeKey, status: .active),
        .init(symbol: "building.columns",                 name: "FINRA",                provides: "空头 / Short Interest",          access: .free,    status: .active),
        .init(symbol: "bubble.left.and.bubble.right",     name: "X (Twitter)",          provides: "讨论 · 情绪",                    access: .byo,     status: .active),
        .init(symbol: "building.columns",                 name: "SEC EDGAR",            provides: "内部人交易(Form 4) · XBRL 财务 · filings", access: .free, status: .planned),
        .init(symbol: "doc.text",                         name: "Yahoo quoteSummary",   provides: "分析师评级 · 财报日 · 机构持股",   access: .free,    status: .planned),
    ]

    private var sources: [DataSourceEntry] {
        market == .cn ? Self.cnSources : Self.usSources
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }

    @ViewBuilder
    private func catalogRow(_ entry: DataSourceEntry) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.gradient)
                .frame(width: 29, height: 29)
                .overlay {
                    Image(systemName: entry.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(entry.provides)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            badge(entry.access.label, entry.access.tint)
            badge(entry.status.label, entry.status.tint)
                .opacity(entry.status == .planned ? 0.6 : 1)
        }
        .padding(.vertical, 3)
    }

    var body: some View {
        Form {
            Section {
                Picker("市场", selection: $market) {
                    ForEach(DSMarket.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ForEach(sources) { entry in
                    catalogRow(entry)
                }
            } header: {
                Text("数据源总览")
            } footer: {
                Text("免费 = 无需 Key;免费·需Key = 在下方填写;自带账号 = 在工作流里登录。计划中 = 即将接入。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if settings.providerKind == .server {
                Section {
                    Text("In Wick Server mode, FMP / Finnhub / FRED are provided by our backend — you don't need to supply data keys. Switch to a BYO provider on the Provider tab to manage your own data sources.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Each data source is its own card: an icon-tiled
                // header row naming the source, the key field below it,
                // and the provider/fallback note as caption. The tile
                // colour codes the source so the three cards scan apart
                // at a glance.
                Section("Fundamentals & price (FMP)") {
                    SettingsRow(systemImage: "chart.bar.doc.horizontal",
                                tint: .blue,
                                title: "Financial Modeling Prep",
                                subtitle: "price history, fundamentals, profile") {
                        EmptyView()
                    }
                    SecureField("FMP API key:", text: $settings.fmpKey)
                    Text("[financialmodelingprep.com](https://site.financialmodelingprep.com/developer) · price history, fundamentals, profile. Empty = Wick falls back to Yahoo for chart-only data.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section("News & sentiment (Finnhub)") {
                    SettingsRow(systemImage: "newspaper",
                                tint: .indigo,
                                title: "Finnhub",
                                subtitle: "company headlines, sentiment") {
                        EmptyView()
                    }
                    SecureField("Finnhub API key:", text: $settings.finnhubKey)
                    Text("[finnhub.io](https://finnhub.io/dashboard) · company headlines, sentiment. Empty = the news/sentiment analysts report \"no data\".")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section("Macro backdrop (FRED)") {
                    SettingsRow(systemImage: "building.columns",
                                tint: .teal,
                                title: "FRED · St. Louis Fed",
                                subtitle: "rates, spreads, unemployment, CPI") {
                        EmptyView()
                    }
                    SecureField("FRED API key:", text: $settings.fredKey)
                    Text("[fred.stlouisfed.org](https://fred.stlouisfed.org/docs/api/api_key.html) · Fed funds, 10y, 10y-2y spread, unemployment, CPI YoY. Free; commercial-OK with attribution. Empty = no macro context in reports.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Provider tab

/// Single switch at the top — Server (SaaS) vs Bring-Your-Own —
/// drives everything below. BYO branch has a provider dropdown
/// (10 hosted clouds + Custom + Local Ollama), an auto-filled
/// base URL, an SecureField for the key, and discovery-populated
/// model dropdowns. Server branch just collects the WickServer
/// base URL (auth coming in v2).
private struct ProviderTab: View {
    @Bindable var settings: AgentSettings
    /// Latest discovery error per provider, surfaced under the
    /// "Refresh models" button. Cleared on a successful refresh.
    @State private var discoveryError: String?
    @State private var discovering: Bool = false

    var body: some View {
        Form {
            Section("Mode") {
                modePicker
                Text(settings.providerKind == .server
                     ? "All LLM traffic routes through Wick's hosted broker. No keys needed on this device — pricing handled via subscription. (Coming soon.)"
                     : "Wick talks directly to the provider with your own key. Nothing touches our servers.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if settings.providerKind == .server {
                Section("Server") {
                    TextField("Server URL:", text: $settings.serverBaseURL)
                    Text("Defaults to our hosted instance once auth wiring lands. For now points at a local WickServer for development.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Section("Provider") {
                    // Rich provider row: a keyed icon-tile + the live
                    // provider name as subtitle, with the dropdown on
                    // the trailing edge.
                    SettingsRow(systemImage: "cpu",
                                tint: .purple,
                                title: "LLM provider",
                                subtitle: settings.providerKind.displayName) {
                        providerPicker
                            .labelsHidden()
                            .frame(maxWidth: 220)
                    }
                    if settings.providerKind == .claudeCode {
                        // No URL / key — Claude Code uses local OAuth.
                        // Just let the user override the binary path if
                        // it's not in $PATH.
                        TextField("`claude` path (optional):",
                                  text: $settings.claudeCodeCLIPath,
                                  prompt: Text("Leave blank to resolve from $PATH"))
                        Text("Drives the Wicker workflow by shelling out to your locally-installed `claude` CLI. Uses whichever subscription `claude login` is signed into — no API key here. Each desk run is ~10-20 s slower than a direct API call and bills against your Pro/Max quota; not recommended for high-frequency use.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        TextField("Base URL:", text: $settings.byoBaseURL)
                        if settings.providerKind.requiresAPIKey {
                            SecureField("API key:", text: $settings.currentAPIKey)
                            Text("Stored in your macOS Keychain. Each provider's key gets its own entry — switching providers preserves the others.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Models") {
                    quickModelField
                    deepModelField
                    HStack {
                        Button {
                            Task { await refreshModels() }
                        } label: {
                            Label(discovering ? "Refreshing…" : "Refresh models",
                                  systemImage: "arrow.clockwise")
                        }
                        .disabled(discovering
                                  || (settings.providerKind.requiresAPIKey
                                      && settings.currentAPIKey.isEmpty))
                        Spacer()
                        if !settings.availableModels.isEmpty {
                            Text("\(settings.availableModels.count) models loaded")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    if let err = discoveryError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Color.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Auto-fetch the provider's /models list whenever the user
        // switches provider OR pastes a new key. Debounced ~700ms
        // so we don't hammer the endpoint on every keystroke; the
        // task is automatically cancelled and re-launched on the
        // next id change. Result: the Quick / Deep / Lite pickers
        // populate themselves without a manual "Refresh models"
        // click, which is what the user actually wants.
        .task(id: discoveryTaskKey) {
            // No key (or keyless provider not yet given a URL) →
            // nothing to fetch. Skip silently rather than spam an
            // error.
            guard providerReadyForDiscovery else { return }
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return }
            await refreshModels()
        }
    }

    /// Re-fires the discovery task whenever the user changes
    /// provider OR the API key. The compound id ensures cancellation
    /// when EITHER input changes — base URL edits also re-fire
    /// since the URL is downstream of the provider choice.
    private var discoveryTaskKey: String {
        "\(settings.providerKind.rawValue)|\(settings.byoBaseURL)|\(settings.currentAPIKey)"
    }

    /// Whether we have enough info to attempt discovery — a real
    /// base URL plus, for providers that need it, a non-empty key.
    private var providerReadyForDiscovery: Bool {
        guard settings.providerKind != .server else { return false }
        guard !settings.byoBaseURL.isEmpty else { return false }
        if settings.providerKind.requiresAPIKey {
            return !settings.currentAPIKey.isEmpty
        }
        return true
    }

    // MARK: - Sub-views

    private var modePicker: some View {
        Picker("Mode:", selection: serverModeBinding) {
            Text("Wick Server (managed)").tag(true)
            Text("Bring Your Own").tag(false)
        }
        .pickerStyle(.segmented)
    }

    /// Routes `providerKind` between `.server` and the last-selected
    /// BYO kind (defaults to Anthropic). Stored in @AppStorage so
    /// flipping back to BYO returns to wherever the user was.
    private var serverModeBinding: Binding<Bool> {
        Binding(
            get: { settings.providerKind == .server },
            set: { isServer in
                if isServer {
                    settings.providerKind = .server
                } else {
                    // Restore last BYO choice; fall back to Anthropic.
                    let raw = UserDefaults.standard.string(forKey: "tf.byo.lastKind")
                        ?? ProviderKind.anthropic.rawValue
                    settings.providerKind = ProviderKind(rawValue: raw) ?? .anthropic
                }
            }
        )
    }

    private var providerPicker: some View {
        Picker("Provider:", selection: byoKindBinding) {
            ForEach(ProviderKind.pickerSections, id: \.title) { section in
                if section.title == "Managed" {
                    EmptyView()  // hide the server case in BYO mode
                } else {
                    Section(section.title) {
                        ForEach(section.items) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                }
            }
        }
        .onChange(of: settings.providerKind) { _, new in
            // Remember the last BYO choice so the mode picker can
            // restore it next time the user toggles out of Server.
            if new != .server {
                UserDefaults.standard.set(new.rawValue, forKey: "tf.byo.lastKind")
            }
            discoveryError = nil
        }
    }

    /// Bind directly to `settings.providerKind` but filter out
    /// `.server` (which is set by the mode picker, not this picker).
    private var byoKindBinding: Binding<ProviderKind> {
        Binding(
            get: { settings.providerKind == .server ? .anthropic : settings.providerKind },
            set: { settings.providerKind = $0 }
        )
    }

    private var quickModelField: some View {
        Picker("Quick model:", selection: $settings.quickModel) {
            ForEach(modelOptions(currentValue: settings.quickModel)) { m in
                Text(modelLabel(m)).tag(m.id)
            }
        }
    }

    private var deepModelField: some View {
        Picker("Deep model:", selection: $settings.deepModel) {
            ForEach(modelOptions(currentValue: settings.deepModel)) { m in
                Text(modelLabel(m)).tag(m.id)
            }
        }
    }

    /// Always-on dropdown options. If discovery has populated
    /// `availableModels`, use the full live list (and append the
    /// current selection as `(custom)` if it isn't in the list so
    /// the picker can show what's actually selected). Pre-discovery
    /// — Settings just opened, key not yet pasted — fall back to
    /// the provider's three recommended defaults plus the current
    /// value, so the field is always a real picker, never a raw
    /// TextField.
    private func modelOptions(currentValue: String) -> [ModelInfo] {
        if !settings.availableModels.isEmpty {
            var out = settings.availableModels
            if !out.contains(where: { $0.id == currentValue }) && !currentValue.isEmpty {
                out.append(ModelInfo(id: currentValue,
                                      displayName: "\(currentValue) (custom)"))
            }
            return out
        }
        let kind = settings.providerKind
        var ids: [String] = []
        for id in [kind.defaultQuickModel,
                   kind.defaultDeepModel,
                   currentValue]
        {
            if !id.isEmpty && !ids.contains(id) { ids.append(id) }
        }
        return ids.map { ModelInfo(id: $0) }
    }

    /// "claude-opus-4-7 · $15/$75 · 200k" — show pricing + context
    /// window inline if the provider's `/models` endpoint surfaced
    /// them (notably OpenRouter does).
    private func modelLabel(_ m: ModelInfo) -> String {
        var parts: [String] = [m.displayName]
        if let inp = m.inputPricePerMillionUSD, let out = m.outputPricePerMillionUSD {
            parts.append(String(format: "$%.2f/$%.2f", inp, out))
        }
        if let ctx = m.contextWindow {
            parts.append("\(ctx / 1000)k")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Discovery

    private func refreshModels() async {
        discovering = true
        discoveryError = nil
        defer { discovering = false }
        guard let url = URL(string: settings.byoBaseURL) else {
            discoveryError = "Invalid base URL."
            return
        }
        let key: String? = settings.providerKind.requiresAPIKey
            ? settings.currentAPIKey
            : nil
        do {
            let models = try await ProviderDiscovery.fetchModels(
                for: settings.providerKind,
                baseURL: url,
                apiKey: key)
            settings.availableModels = models
        } catch {
            discoveryError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

// MARK: - Workflow tab

private struct WorkflowTab: View {
    @Bindable var settings: AgentSettings

    var body: some View {
        Form {
            Section("Analysts") {
                // The four shared analysts run on every ticker (US, intl, CN).
                ForEach(Self.sharedAnalysts, id: \.self) { kind in
                    Toggle(kind.rawValue.capitalized,
                           isOn: bindingFor(kind))
                }
                Text("Disabled analysts are skipped — fewer LLM calls per report.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Chinese-market analysts") {
                // policy / capital only run for A-share / HK tickers — the desk
                // routes them in per-symbol, so these toggles are no-ops for US
                // / intl names. Surfaced separately so the distinction is clear.
                ForEach(Self.chineseOnlyAnalysts, id: \.self) { kind in
                    Toggle(Self.chineseAnalystLabel(kind),
                           isOn: bindingFor(kind))
                }
                Text("政策面 / 资金面 — only run for A-share (.SS/.SZ) and Hong Kong (.HK) tickers. 资金面 is A-share-only; HK has no main-force fund-flow data.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Debate") {
                LabeledContent("Bull ↔ bear rounds:") {
                    HStack(spacing: 6) {
                        Stepper("", value: $settings.maxDebateRounds, in: 0...4)
                            .labelsHidden()
                        Text("\(settings.maxDebateRounds)").monospacedDigit()
                    }
                }
                Text("0 skips the debate entirely. Each round = 2 LLM calls.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Self-conditioning") {
                LabeledContent("History depth:") {
                    HStack(spacing: 6) {
                        Stepper("", value: $settings.historyDepth, in: 0...20)
                            .labelsHidden()
                        Text("\(settings.historyDepth) reports").monospacedDigit()
                    }
                }
                Text("Past calls on the same ticker (rating + position) are inlined into the trader's prompt so it can change its mind on contradicting evidence. 0 disables.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Sampling") {
                LabeledContent("Temperature:") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.temperature, in: 0...1.5, step: 0.05)
                            .frame(maxWidth: 180)
                        Text(String(format: "%.2f", settings.temperature))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("BYO 浏览器（实验）") {
                // Rich toggle rows: icon-tile + the existing long
                // descriptions promoted to subtitle, control on the
                // trailing edge.
                SettingsRow(systemImage: "globe",
                            tint: .blue,
                            title: "启用 Wicker 浏览器工具",
                            subtitle: "让 Wicker 通过内嵌 WebKit 导航 / 读取 / 操作网页(navigate·read·snapshot·click·type·eval·fetchJSON)。开启后,在聊天里要它浏览时会自动滑出实时浏览面板,可登录/接管。默认关,macOS 26+。") {
                    Toggle("", isOn: $settings.enableWickerBrowser)
                        .labelsHidden()
                }
                // One-switch write guardrail. ON (default) = Wicker may
                // click / type / run scripts on pages. OFF = read-only: it can
                // still navigate / read / snapshot, but click·type·eval are
                // refused with a hint back to this switch.
                SettingsRow(systemImage: settings.allowWickerBrowserWrites
                                ? "hand.tap" : "hand.raised",
                            tint: settings.allowWickerBrowserWrites ? .orange : .secondary,
                            title: "允许浏览器写操作(点击 / 输入 / 执行脚本)",
                            subtitle: "护栏开关。关闭后 Wicker 进入只读模式:仍可导航 / 读取 / 快照页面,但不会点击、输入或执行脚本(改用提示让你去开启)。默认开。仅在已启用 Wicker 浏览器时生效。") {
                    Toggle("", isOn: $settings.allowWickerBrowserWrites)
                        .labelsHidden()
                        .disabled(!settings.enableWickerBrowser)
                }
                SettingsRow(systemImage: "bubble.left.and.text.bubble.right",
                            tint: .green,
                            title: "雪球 BYO 讨论(情绪源)",
                            subtitle: "把你登录的雪球个股讨论纳入情绪分析。默认关;需先在个股 Social tab 连接雪球登录。") {
                    Toggle("", isOn: $settings.enableXueqiuSentiment)
                        .labelsHidden()
                }
                // Cross-process MCP bridge exposure (TODO #39). Lets third-party
                // MCP clients (Claude Code / Codex / …) drive the user's
                // logged-in browser + 雪球/X session over the bundled wick-mcp
                // server. Sensitive — default OFF, gated by the browser switch.
                SettingsRow(systemImage: "antenna.radiowaves.left.and.right",
                            tint: .red,
                            title: "通过 MCP 暴露 Wicker 浏览器/社交(只读)",
                            subtitle: "允许第三方 MCP 客户端(Claude Code / Codex 等)通过内置 wick-mcp 驱动你已登录的浏览器与雪球/X 会话——仅只读:导航 / 读取 / 快照 / 雪球·X 讨论(不含点击 / 输入 / 执行脚本)。⚠️ 这会让外部 agent 操作你的登录会话。默认关;需先启用上方「Wicker 浏览器」,macOS 26+。") {
                    Toggle("", isOn: $settings.exposeWickerViaMCP)
                        .labelsHidden()
                        .disabled(!settings.enableWickerBrowser)
                }
                // Fixed width of the live-browser panel. Only WIDTH is tunable —
                // the panel always fills the window height; in the chat view the
                // browser is locked (drag the divider to resize the chat column
                // instead). The render clamps this against the window so a wide
                // setting on a narrow window auto-shrinks, never squeezing the
                // chat away.
                SettingsRow(systemImage: "rectangle.split.2x1",
                            tint: .blue,
                            title: "浏览器宽度",
                            subtitle: "Wicker 浏览器面板的固定宽度(高度填满窗口)。窗口窄时会自动缩,保证聊天可用。") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(settings.wickerBrowserWidth) },
                                set: { settings.wickerBrowserWidth = Int($0) }
                            ),
                            in: 600...1280,
                            step: 20
                        )
                        .frame(width: 160)
                        Text("\(settings.wickerBrowserWidth)pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The four analysts that run on every desk, in canonical order.
    private static let sharedAnalysts: [AnalystKind] =
        [.fundamental, .technical, .sentiment, .news]
    /// CN-desk-only analysts, surfaced under their own section.
    private static let chineseOnlyAnalysts: [AnalystKind] = [.policy, .capital]

    private static func chineseAnalystLabel(_ kind: AnalystKind) -> String {
        switch kind {
        case .policy:  return "Policy · 政策面"
        case .capital: return "Capital · 资金面"
        default:       return kind.rawValue.capitalized
        }
    }

    private func bindingFor(_ kind: AnalystKind) -> Binding<Bool> {
        Binding(
            get: { settings.analysts.contains(kind) },
            set: { on in
                if on { settings.analysts.insert(kind) }
                else  { settings.analysts.remove(kind) }
            }
        )
    }
}

// MARK: - Free agent tab

private struct FreeAgentTab: View {
    @Bindable var settings: AgentSettings

    var body: some View {
        Form {
            Section("Tool loop") {
                LabeledContent("Max tool turns:") {
                    HStack(spacing: 6) {
                        Stepper("", value: $settings.freeAgentMaxToolTurns, in: 1...20)
                            .labelsHidden()
                        Text("\(settings.freeAgentMaxToolTurns)").monospacedDigit()
                    }
                }
                Text("Hard cap on how many tool round-trips the chat agent can take before it must answer. Belt-and-suspenders against runaway loops.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Model") {
                Text("The free agent uses the **Deep model** set in Provider.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Skills tab

private struct SkillsTab: View {
    @Bindable var settings: AgentSettings
    @State private var loadedSkills: [Skill] = []
    @State private var picking = false

    var body: some View {
        Form {
            Section("Your skill folder") {
                LabeledContent("Folder:") {
                    HStack {
                        Text(settings.userSkillsDirectoryPath ?? "Not set — bundled only")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { picking = true }
                        if settings.userSkillsDirectoryPath != nil {
                            Button("Clear") { settings.userSkillsDirectoryPath = nil }
                        }
                    }
                }
                Text("Drop `.md` files with `name` and `description` frontmatter into this folder; same-name files override the bundled skill.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Loaded skills") {
                if loadedSkills.isEmpty {
                    Text("(loading…)").font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(loadedSkills) { skill in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(skill.name)
                                    .font(.system(size: 13, design: .monospaced))
                                Spacer()
                                Text(badge(for: skill.source))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            Text(skill.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: settings.userSkillsDirectoryPath) { await refresh() }
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                settings.userSkillsDirectoryPath = url.path
            }
        }
    }

    private func refresh() async {
        let reg = SkillRegistry(userDirectory: settings.userSkillsDirectoryURL)
        await reg.reload()
        let all = await reg.all()
        await MainActor.run { self.loadedSkills = all }
    }

    private func badge(for source: Skill.Source) -> String {
        switch source {
        case .bundled: return "BUNDLED"
        case .user:    return "USER"
        }
    }
}

// MARK: - Appearance tab

private struct AppearanceTab: View {
    @Bindable var settings: AgentSettings

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance:", selection: $settings.appearanceOverride) {
                    Text("System").tag(ColorScheme?.none)
                    Text("Light").tag(ColorScheme?.some(.light))
                    Text("Dark").tag(ColorScheme?.some(.dark))
                }
                .pickerStyle(.segmented)
            }
            Section("Chart") {
                Toggle("Side-by-side pane in Chart tab",
                       isOn: $settings.chartSplitView)
            }
            Section("Macro 宏观") {
                Picker("Layout 布局:", selection: $settings.macroTwoColumn) {
                    Text("一览 (single)").tag(false)
                    Text("两栏 (two-column)").tag(true)
                }
                .pickerStyle(.segmented)

                Picker("Time interval 时间区间:", selection: $settings.macroWindowMonths) {
                    Text("3M").tag(3)
                    Text("6M").tag(6)
                    Text("1Y").tag(12)
                    Text("2Y").tag(24)
                    Text("5Y").tag(60)
                }
                .pickerStyle(.segmented)

                Picker("Column 1 default 第一栏:", selection: $settings.macroColumn1) {
                    ForEach(MacroCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat.rawValue)
                    }
                }

                Picker("Column 2 default 第二栏:", selection: $settings.macroColumn2) {
                    ForEach(MacroCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat.rawValue)
                    }
                }
                .disabled(!settings.macroTwoColumn)

                Text("两栏布局并排显示两个分类面板，各自独立切换。时间区间控制每个图表的可视窗口长度。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Watchlist") {
                Picker("Change display:", selection: $settings.watchlistChangeStyle) {
                    ForEach(WatchlistChangeStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Text("Show the day-over-day move as an absolute price delta or a percent change. Affects sidebar rows only.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
