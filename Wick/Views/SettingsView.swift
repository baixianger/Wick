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
        }
        // Grouped forms are taller (cards + headers) and scroll, so a
        // comfortable min keeps the first card un-clipped while the
        // window still opens compact.
        .frame(minWidth: 820, idealWidth: 860, minHeight: 580, idealHeight: 680)
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

    var body: some View {
        Form {
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
                SettingsRow(systemImage: "bubble.left.and.text.bubble.right",
                            tint: .green,
                            title: "雪球 BYO 讨论(情绪源)",
                            subtitle: "把你登录的雪球个股讨论纳入情绪分析。默认关;需先在个股 Social tab 连接雪球登录。") {
                    Toggle("", isOn: $settings.enableXueqiuSentiment)
                        .labelsHidden()
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
