import SwiftUI

@main
struct WickApp: App {

    /// Process-wide live-data cache. Passed through the environment so
    /// every view can pull the freshest Yahoo series without prop drilling.
    @State private var dataStore = LiveDataStore()
    /// Global chart-indicator config — same reference shared between
    /// ContentView (per-ticker chart sheet) and Settings (Indicators
    /// tab) so edits in one surface land in the other.
    @State private var indicatorConfig = ChartIndicatorConfig()
    /// FRED (St. Louis Fed) live-data cache for the Macro tab. Key is
    /// adopted from `AgentSettings.fredKey` on launch + whenever the
    /// user pastes a fresh one in Settings — same flow as the other
    /// data-source keys.
    @State private var fredStore = FredDataStore()
    /// EastMoney short-name cache for CN/HK tickers. In Chinese UI mode the
    /// ticker-NAME sites read through this to show 简称 (e.g. "贵州茅台")
    /// instead of the broker / English name. Shared via the environment like
    /// the other data stores. See `CNNameStore`.
    @State private var cnNames = CNNameStore()
    /// Real per-ticker news cache for the Overview / News tabs — the live
    /// replacement for `NewsFixtures`. Routes CN/HK tickers to EastMoney 资讯
    /// and US / international to Yahoo Finance, caching per symbol. Shared via
    /// the environment like the other data stores. See `NewsStore`.
    @State private var newsStore = NewsStore()
    /// BYO agent settings (LLM key in Keychain, model choices, agent knobs,
    /// appearance, chart layout — see AgentSettings). Shared via the
    /// environment so any view can read or bind.
    @State private var agentSettings = AgentSettings()
    /// Historical desk-run reports, persisted to disk. The AI tab reads
    /// this on appear and shows the per-ticker history as its default
    /// surface — landing users on "what's been analyzed before" instead
    /// of a cold "Run analysis" gate.
    @State private var reportHistory = ReportHistoryStore()
    /// Shared `ToolRegistry` + `SkillRegistry` for the agent layer.
    /// Both Wicker (the chat agent) and the workflow agent reach
    /// market data / sentiment / skills through this — keeps tool
    /// authoring in one place and matches the agent-runtime decision
    /// already in memory.
    @State private var agentRuntime = AgentRuntime()

    var body: some Scene {
        // No window title — the app is already called "Wick" (visible
        // in the menu bar + Dock), so a redundant "Wick" header inside
        // the window costs ~30 pt of vertical space for zero info.
        // `.hiddenTitleBar` collapses the title bar entirely; traffic
        // lights inset into the content area like Music / Mail / Notes,
        // and the toolbar (segmented tab picker, etc.) lifts into the
        // freed strip. This is the macOS 26 modern-app norm.
        WindowGroup {
            ContentView()
                // i18n runtime switch: changing the language flips
                // `agentSettings.appLanguage`, and this `.id(...)` forces a
                // full view-tree rebuild so every auto-localized `Text`,
                // `LocalizedStringKey` label and `String(localized:)` helper
                // re-resolves against the new environment locale. (This also
                // resets transient view state — acceptable for a deliberate
                // language switch.)
                .id(agentSettings.appLanguage)
                .frame(minWidth: 1180, minHeight: 760)
                .environment(dataStore)
                .environment(fredStore)
                .environment(cnNames)
                .environment(newsStore)
                .environment(agentSettings)
                .environment(reportHistory)
                .environment(agentRuntime)
                .environment(indicatorConfig)
                // Native String Catalog localization + number / date
                // formatting follow the chosen language. `.system` resolves to
                // `autoupdatingCurrent` (no override).
                .environment(\.locale, agentSettings.resolvedLocale)
                // Apply on the root view of the WindowGroup — that's the
                // only placement macOS extends into the window's title
                // bar / toolbar / sidebar chrome. Applied below this point
                // (e.g. on a NavigationSplitView) it stops at the view
                // tree and the toolbar would stay bright.
                .preferredColorScheme(agentSettings.appearanceOverride)
                .onAppear {
                    // i18n: seed the imperative-localization locale used by the
                    // non-SwiftUI `String(localized:locale:)` call sites.
                    LocaleHolder.current = agentSettings.resolvedLocale
                    // Build the BYO data chain from current keys.
                    agentRuntime.reconfigure(with: agentSettings)
                    // Evaluate the MCP bridge gate on launch: starts the
                    // GUI-side BridgeServer iff the user opted in.
                    agentRuntime.reconfigureBridge(with: agentSettings)
                    // Hand the FRED cache the user's key so Macro
                    // tab cards switch from synthetic to live within
                    // ~1 s of first visit.
                    fredStore.apiKey = agentSettings.fredKey
                }
                // Re-register the agent's MarketDataTool whenever a
                // data-source key changes so the very next chat /
                // workflow call sees the new chain. Each of the three
                // changes funnels through here independently.
                .onChange(of: agentSettings.fmpKey) { _, _ in
                    agentRuntime.reconfigure(with: agentSettings)
                }
                .onChange(of: agentSettings.finnhubKey) { _, _ in
                    agentRuntime.reconfigure(with: agentSettings)
                }
                .onChange(of: agentSettings.fredKey) { _, _ in
                    agentRuntime.reconfigure(with: agentSettings)
                    fredStore.apiKey = agentSettings.fredKey
                }
                // Toggling the BYO 雪球 source rebuilds the chain so the next
                // run picks up (or drops) the off-by-default decorator.
                .onChange(of: agentSettings.enableXueqiuSentiment) { _, _ in
                    agentRuntime.reconfigure(with: agentSettings)
                }
                // Opting Wicker's browser tools on/off registers or retracts
                // the 7 `web.*` tools so the next chat turn (and the live
                // panel's gate) reflect the change immediately.
                .onChange(of: agentSettings.enableWickerBrowser) { _, _ in
                    agentRuntime.reconfigureWebTools(with: agentSettings)
                    // The bridge gate also depends on this flag — re-evaluate so
                    // turning the browser off also stops the MCP bridge.
                    agentRuntime.reconfigureBridge(with: agentSettings)
                }
                // Opting the MCP bridge on/off starts or stops the GUI-side
                // BridgeServer immediately, so third-party MCP clients can (or
                // can no longer) drive the logged-in browser/社交 session.
                .onChange(of: agentSettings.exposeWickerViaMCP) { _, _ in
                    agentRuntime.reconfigureBridge(with: agentSettings)
                }
                // Flipping the write guardrail re-registers click/type/eval as
                // either live actions or read-only refusals — takes effect on
                // the next chat turn with no rebuild.
                .onChange(of: agentSettings.allowWickerBrowserWrites) { _, _ in
                    agentRuntime.reconfigureWebTools(with: agentSettings)
                }
                // i18n: when the user picks a language, update the imperative
                // locale BEFORE the `.id(...)` rebuild swaps the tree so the
                // freshly-built `String(localized:locale:)` calls read it.
                .onChange(of: agentSettings.appLanguage) { _, _ in
                    LocaleHolder.current = agentSettings.resolvedLocale
                }
        }
        // Hidden title bar: the (empty) title strip collapses, so the macOS
        // window tab bar rises into the TOP row beside the traffic lights —
        // a single-row chrome instead of an empty title strip ABOVE the tab
        // bar. Content still respects the top safe area (no `.ignoresSafeArea`),
        // so it stacks cleanly under the tab row with no overlap / fullscreen
        // clipping. Window tabbing stays at its macOS default (enabled).
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        // Dev-only: expose the 雪球 WebPage BYO-cookie probe behind a
        // "Developer" menu command that opens its own window. The whole
        // thing is `#if DEBUG`, so it never reaches a Release build or the
        // user-facing navigation — it's a hand-run validation surface for
        // the two scraping linchpins (see XueqiuProbeView).
        #if DEBUG
        .commands {
            CommandMenu("Developer") {
                XueqiuProbeMenuButton()
                // Sibling to the 雪球 probe: the hard-case X (Twitter)
                // data-reachability probe (DOM + API paths). Same DEBUG-only,
                // hand-run, never-in-user-nav contract.
                XProbeMenuButton()
            }
        }
        #endif

        // The probe's own window. Declared at the `App` level (only in DEBUG)
        // and opened on demand by the Developer-menu command above; it never
        // shows unless explicitly opened.
        #if DEBUG
        Window("雪球 BYO-Cookie Probe (DEV)", id: XueqiuProbeWindow.id) {
            if #available(macOS 26.0, *) {
                XueqiuProbeView()
            } else {
                Text("雪球 Probe 需要 macOS 26")
                    .padding()
            }
        }
        .defaultSize(width: 1000, height: 640)
        #endif

        // The X (Twitter) probe's own window — sibling to the 雪球 one above.
        // DEBUG-only, opened on demand by its Developer-menu command; never
        // shows unless explicitly opened, never in user-facing nav.
        #if DEBUG
        Window("X (Twitter) 数据可达性 Probe (DEV)", id: XProbeWindow.id) {
            if #available(macOS 26.0, *) {
                XProbeView()
            } else {
                Text("X Probe 需要 macOS 26")
                    .padding()
            }
        }
        .defaultSize(width: 1040, height: 660)
        #endif

        // Native macOS Settings scene — reachable via ⌘, and the
        // standard "Wick › Settings…" menu item. SwiftUI auto-wires
        // the menu item to this Scene's content. `SettingsView` is a
        // two-column `NavigationSplitView` (category sidebar + detail,
        // the System Settings look) and carries its own fixed window
        // size via `.frame(minWidth:…)` on the split-view root — so no
        // explicit frame is needed here.
        Settings {
            SettingsView(settings: agentSettings)
                // Same i18n rebuild trick as ContentView so the Settings tree
                // re-resolves its auto-localized labels when the language
                // changes.
                .id(agentSettings.appLanguage)
                .environment(dataStore)
                .environment(fredStore)
                .environment(cnNames)
                .environment(agentSettings)
                .environment(reportHistory)
                .environment(agentRuntime)
                .environment(indicatorConfig)
                .environment(\.locale, agentSettings.resolvedLocale)
        }
        // macOS Settings/Preferences windows are FIXED by default — without
        // this the `.frame(maxWidth/Height: .infinity)` on the split-view
        // root has no effect and the window won't resize. `.contentSize`
        // lets the user drag it within the content's min…max (max .infinity),
        // so it opens at the ideal size yet resizes freely.
        .windowResizability(.contentSize)
    }
}
