import SwiftUI
import TradingFloor

/// Native macOS Preferences pane. Renders as the standard
/// icon-above-label tab strip Apple's first-party apps use (Mail,
/// Notes, Calendar) — that chrome comes free from putting a `TabView`
/// inside the App's `Settings { ... }` Scene.
///
/// Pattern mirrors the user's lingu app for consistency:
///   - `TabView` with one `.tabItem { Label(name, systemImage: icon) }`
///     per tab — macOS supplies the icon-above-label tab strip and
///     auto-titles the window to the active tab.
///   - Each tab is a `Form` with `.formStyle(.columns)` for the
///     `"Label:  control"` Mail.app row pattern.
///   - Per-tab `.frame(width: 440)` + `.fixedSize(horizontal: false,
///     vertical: true)` lets the Preferences window auto-resize to
///     the active tab's natural height.
///   - No `NavigationStack`, no Done button — the close-window red
///     dot dismisses, matching System Settings.
struct SettingsView: View {
    @Bindable var settings: AgentSettings

    var body: some View {
        TabView {
            ProviderTab(settings: settings)
                .tabItem { Label("Provider", systemImage: "key.fill") }

            WorkflowTab(settings: settings)
                .tabItem { Label("Workflow", systemImage: "list.bullet.indent") }

            FreeAgentTab(settings: settings)
                .tabItem { Label("Free Agent", systemImage: "bubble.left.and.bubble.right") }

            SkillsTab(settings: settings)
                .tabItem { Label("Skills", systemImage: "book.closed") }

            AppearanceTab(settings: settings)
                .tabItem { Label("Display", systemImage: "paintpalette") }
        }
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
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.providerKind == .server {
                Section("Server") {
                    TextField("Server URL:", text: $settings.serverBaseURL)
                    Text("Defaults to our hosted instance once auth wiring lands. For now points at a local WickServer for development.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Provider") {
                    providerPicker
                    TextField("Base URL:", text: $settings.byoBaseURL)
                    if settings.providerKind.requiresAPIKey {
                        SecureField("API key:", text: $settings.currentAPIKey)
                        Text("Stored in your macOS Keychain. Each provider's key gets its own entry — switching providers preserves the others.")
                            .font(.caption).foregroundStyle(.secondary)
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
        .formStyle(.columns)
        .padding(20)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder
    private var quickModelField: some View {
        if settings.availableModels.isEmpty {
            TextField("Quick model:", text: $settings.quickModel)
        } else {
            Picker("Quick model:", selection: $settings.quickModel) {
                ForEach(settings.availableModels) { m in
                    Text(modelLabel(m)).tag(m.id)
                }
                if !settings.availableModels.contains(where: { $0.id == settings.quickModel }) {
                    Text("\(settings.quickModel) (custom)").tag(settings.quickModel)
                }
            }
        }
    }

    @ViewBuilder
    private var deepModelField: some View {
        if settings.availableModels.isEmpty {
            TextField("Deep model:", text: $settings.deepModel)
        } else {
            Picker("Deep model:", selection: $settings.deepModel) {
                ForEach(settings.availableModels) { m in
                    Text(modelLabel(m)).tag(m.id)
                }
                if !settings.availableModels.contains(where: { $0.id == settings.deepModel }) {
                    Text("\(settings.deepModel) (custom)").tag(settings.deepModel)
                }
            }
        }
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
                ForEach(AnalystKind.allCases, id: \.self) { kind in
                    Toggle(kind.rawValue.capitalized,
                           isOn: bindingFor(kind))
                }
                Text("Disabled analysts are skipped — fewer LLM calls per report.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    .font(.caption).foregroundStyle(.secondary)
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
                    .font(.caption).foregroundStyle(.secondary)
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
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Model") {
                Text("The free agent uses the **Deep model** set in Provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Loaded skills") {
                if loadedSkills.isEmpty {
                    Text("(loading…)").font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(loadedSkills) { skill in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(skill.name)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Text(badge(for: skill.source))
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            Text(skill.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
