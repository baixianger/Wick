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
                .frame(minWidth: 1180, minHeight: 760)
                .environment(dataStore)
                .environment(fredStore)
                .environment(agentSettings)
                .environment(reportHistory)
                .environment(agentRuntime)
                .environment(indicatorConfig)
                // Apply on the root view of the WindowGroup — that's the
                // only placement macOS extends into the window's title
                // bar / toolbar / sidebar chrome. Applied below this point
                // (e.g. on a NavigationSplitView) it stops at the view
                // tree and the toolbar would stay bright.
                .preferredColorScheme(agentSettings.appearanceOverride)
                .onAppear {
                    // Build the BYO data chain from current keys.
                    agentRuntime.reconfigure(with: agentSettings)
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
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)

        // Native macOS Settings scene — reachable via ⌘, and the
        // standard "Wick › Settings…" menu item. SwiftUI auto-wires
        // the menu item to this Scene's content and supplies the
        // standard Preferences chrome (icon-above-label tab strip,
        // window auto-resizes to the active tab's `.frame(width:)`).
        // No explicit frame here — each tab in `SettingsView` sets
        // its own width via `.fixedSize`, à la Apple's first-party
        // apps (Mail.app, lingu).
        Settings {
            SettingsView(settings: agentSettings)
                .environment(dataStore)
                .environment(fredStore)
                .environment(agentSettings)
                .environment(reportHistory)
                .environment(agentRuntime)
                .environment(indicatorConfig)
        }
    }
}
