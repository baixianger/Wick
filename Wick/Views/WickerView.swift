import SwiftUI
import TradingFloor

/// Wicker — the global chat / analysis agent. Layout cribs from the new
/// macOS 26 Mail.app: a session column (Mail's message list) on the left
/// and a conversation pane (Mail's reading pane) on the right. The app
/// sidebar already supplies the third column ("accounts / mailboxes"),
/// so the full screen reads as the same three-pane shape users now
/// expect from Apple's first-party apps.
///
/// Per [[wick-business-model]] the user supplies the LLM provider —
/// Anthropic key OR an OpenAI-compatible local endpoint (Ollama). We
/// build a fresh provider per turn so settings changes take effect
/// without rebuilding the view.
struct WickerView: View {
    @Bindable var store: ChatStore
    @Environment(AgentSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    /// Shared namespace for the session-row glass selection capsule.
    /// `glassEffectID` keyed to "sessionSelection" makes the capsule
    /// morph between rows on selection change instead of crossfade.
    @Namespace private var sessionMorphNS
    /// Rename-flow state. `renamingSessionID` is the session whose
    /// title the alert is currently editing; `renameDraft` is the
    /// in-progress text. Hoisted here so the alert lives at the
    /// WickerView level — one instance for all rows, no per-row
    /// alert state.
    @State private var renamingSessionID: UUID?
    @State private var renameDraft: String = ""

    var body: some View {
        HStack(spacing: 0) {
            sessionColumn
                .frame(width: 300)
            Divider()
            conversationPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(appleBackground(for: colorScheme))
        .onAppear { ensureSession() }
        .onChange(of: store.sessions.count) { _, _ in ensureSession() }
        .alert("Rename session",
               isPresented: Binding(
                get: { renamingSessionID != nil },
                set: { if !$0 { renamingSessionID = nil } }
               ))
        {
            TextField("Title", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingSessionID = nil }
            Button("Rename") { commitRename() }
        }
    }

    /// Make sure the right pane always has SOMETHING to render — the
    /// "no sessions" empty-state with a centered button felt
    /// redundant next to the right pane's own hero. Auto-creating an
    /// empty "New chat" session lands the user directly on the hero
    /// input (à la Claude). Only kicks in when truly empty (entering
    /// Wicker first time, or after deleting the last session).
    private func ensureSession() {
        if store.sessions.isEmpty {
            store.newSession()
        }
    }

    private func commitRename() {
        guard let id = renamingSessionID else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { store.rename(id: id, to: trimmed) }
        renamingSessionID = nil
    }

    // MARK: - Session column (Mail's message-list position)

    /// The left rail. `ensureSession()` guarantees the list is never
    /// empty in normal flow, so a fall-through to `emptyColumn` only
    /// happens for the brief instant before `onAppear` fires.
    private var sessionColumn: some View {
        VStack(spacing: 0) {
            sessionColumnHeader
            if store.sessions.isEmpty {
                emptyColumn
            } else {
                sessionList
            }
        }
    }

    private var sessionColumnHeader: some View {
        HStack(spacing: 6) {
            Text("Sessions")
                .font(.system(size: 13, weight: .semibold))
            Text("\(store.sessions.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            Spacer()
            Button {
                store.newSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("New chat")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Safety fallback — almost never rendered (ensureSession auto-
    /// creates the first session on appear). The right pane's hero
    /// carries the actual onboarding affordance now.
    private var emptyColumn: some View {
        Spacer()
    }

    /// Grouped session list with Mail-style date headers (Today /
    /// Yesterday / This Week / Earlier) and a flat gray selection
    /// fill. Groups built fresh on every render — cheap: the
    /// underlying array is already sorted newest-first by the store.
    /// `matchedGeometryEffect` on the selection rectangle morphs it
    /// between rows on selection change.
    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 1, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedSessions, id: \.label) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            SessionRow(
                                session: session,
                                selected: session.id == store.selectedSessionID,
                                morphNamespace: sessionMorphNS
                            )
                            .onTapGesture {
                                withAnimation(.snappy(duration: 0.22)) {
                                    store.selectedSessionID = session.id
                                }
                            }
                            .contextMenu {
                                Button {
                                    renameDraft = session.title
                                    renamingSessionID = session.id
                                } label: {
                                    Label("Rename…", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    store.delete(id: session.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        sectionHeader(group.label)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.clear)
    }

    private var groupedSessions: [SessionGroup] {
        SessionGroup.build(from: store.sessions, now: .now)
    }

    // MARK: - Conversation pane

    @ViewBuilder
    private var conversationPane: some View {
        if let session = store.session(for: store.selectedSessionID) {
            ConversationView(store: store, session: session)
        } else {
            // Brief blank during the layout pass before ensureSession
            // fires. Once a session exists ConversationView takes
            // over — its hero state is the actual empty-state UI.
            Color.clear
        }
    }
}

// MARK: - Date-grouped session bucketing

/// Mail-style date buckets. "Today" / "Yesterday" use calendar
/// comparison (not 24h windows), "This Week" is the rest of the
/// current ISO week, everything older falls into "Earlier" — which
/// keeps the list bounded even after months of usage without needing
/// pagination.
struct SessionGroup {
    let label: String
    let sessions: [ChatSession]

    static func build(from sessions: [ChatSession], now: Date) -> [SessionGroup] {
        let cal = Calendar.current
        var today: [ChatSession] = []
        var yesterday: [ChatSession] = []
        var thisWeek: [ChatSession] = []
        var earlier: [ChatSession] = []
        let yesterdayDate = cal.date(byAdding: .day, value: -1, to: now) ?? now
        for s in sessions {
            if cal.isDate(s.updatedAt, inSameDayAs: now) {
                today.append(s)
            } else if cal.isDate(s.updatedAt, inSameDayAs: yesterdayDate) {
                yesterday.append(s)
            } else if cal.isDate(s.updatedAt, equalTo: now, toGranularity: .weekOfYear) {
                thisWeek.append(s)
            } else {
                earlier.append(s)
            }
        }
        var groups: [SessionGroup] = []
        if !today.isEmpty     { groups.append(.init(label: "TODAY", sessions: today)) }
        if !yesterday.isEmpty { groups.append(.init(label: "YESTERDAY", sessions: yesterday)) }
        if !thisWeek.isEmpty  { groups.append(.init(label: "THIS WEEK", sessions: thisWeek)) }
        if !earlier.isEmpty   { groups.append(.init(label: "EARLIER", sessions: earlier)) }
        return groups
    }
}

// MARK: - Session row (Mail-style preview)

private struct SessionRow: View {
    let session: ChatSession
    let selected: Bool
    /// Inherited namespace from `WickerView` so the selection capsule
    /// uses `matchedGeometryEffect` + `glassEffectID` to morph between
    /// rows. The id is shared ("sessionSelection") so only the
    /// currently-selected row's overlay is in the hierarchy at any
    /// given time — SwiftUI animates the position change.
    let morphNamespace: Namespace.ID

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let sym = session.pinnedSymbol {
                        Text(sym)
                            .font(.system(size: 10, weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15),
                                        in: Capsule())
                    }
                    Spacer()
                    Text(timeStamp)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(previewText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            if selected {
                // Subtle gray fill — no glass, no blue tint. Glass
                // selection muddled the text contrast on this dense
                // row (title + preview + time), and a blue fill
                // would fight the global sidebar's native blue. A
                // flat `Color.primary.opacity(0.08)` reads as
                // "selected" without obscuring anything underneath.
                // matchedGeometryEffect still drives the row-to-row
                // morph on selection change.
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .matchedGeometryEffect(id: "sessionSelection",
                                            in: morphNamespace)
            }
        }
    }

    private var previewText: String {
        // Prefer the assistant's most recent reply (richer summary)
        // and fall back to the user's last question when there is no
        // reply yet.
        if let lastAssistant = session.messages.last(where: { $0.role == .assistant }) {
            return lastAssistant.text.replacingOccurrences(of: "\n", with: " ")
        }
        if let lastUser = session.messages.last(where: { $0.role == .user }) {
            return "You: " + lastUser.text.replacingOccurrences(of: "\n", with: " ")
        }
        return "No messages yet"
    }

    private var timeStamp: String {
        let cal = Calendar.current
        let now = Date.now
        if cal.isDate(session.updatedAt, inSameDayAs: now) {
            return session.updatedAt.formatted(date: .omitted, time: .shortened)
        }
        let yesterday = cal.date(byAdding: .day, value: -1, to: now) ?? now
        if cal.isDate(session.updatedAt, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if cal.isDate(session.updatedAt, equalTo: now, toGranularity: .weekOfYear) {
            return session.updatedAt.formatted(.dateTime.weekday(.abbreviated))
        }
        return session.updatedAt.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Conversation pane (right column)

private struct ConversationView: View {
    @Bindable var store: ChatStore
    /// Snapshot at construction; we re-read the live copy off `store`
    /// inside the body so appends rerender. Kept here for the id.
    let session: ChatSession

    @Environment(AgentSettings.self) private var settings
    @Environment(AgentRuntime.self) private var runtime
    @State private var draft: String = ""
    @State private var pending: Bool = false
    /// Live label shown in the pending indicator — switches between
    /// "thinking…" and "calling <tool>…" as the tool loop progresses.
    /// `nil` falls back to the animated dots.
    @State private var pendingLabel: String?
    @State private var lastError: String?
    @FocusState private var inputFocused: Bool

    private var live: ChatSession {
        store.session(for: session.id) ?? session
    }

    var body: some View {
        // Two layouts:
        //   - HERO   : empty session — greeting + centered composer
        //              + suggestion chips, à la Claude's landing page.
        //              Composer is the focal point, vertically
        //              centered, not stuck at the bottom.
        //   - NORMAL : transcript above, composer pinned at bottom.
        // Same `submit()` powers both — only the spatial framing
        // around the composer differs.
        if showHero {
            heroLayout
        } else {
            VStack(spacing: 0) {
                transcript
                composer
            }
        }
    }

    /// True when this session has no real activity yet — fresh chat,
    /// nothing pending, no transient error. The hero shows in that
    /// window and disappears the instant the first user message is
    /// appended (which `submit()` does synchronously).
    private var showHero: Bool {
        live.messages.isEmpty && !pending && lastError == nil
    }

    // MARK: Hero (empty state)

    private var heroLayout: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 40)
            heroHeader
            composer
                .frame(maxWidth: 720)
            heroSuggestions
                .frame(maxWidth: 720)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var heroHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.accentColor.gradient)
                .symbolEffect(.breathe)
            Text(timeOfDayGreeting)
                .font(.system(size: 26, weight: .medium, design: .serif))
                .foregroundStyle(.primary)
        }
    }

    /// Tap a chip to one-shot the question — drops it straight into
    /// `draft` and dispatches the same `submit()` path as the
    /// composer's Send button.
    private var heroSuggestions: some View {
        let prompts = [
            "How is NVDA doing today?",
            "Compare AAPL and MSFT margins",
            "Screen S&P 500 for P/E < 15",
            "What's the macro setup for tech?",
        ]
        return HStack(spacing: 8) {
            ForEach(prompts, id: \.self) { p in
                Button {
                    draft = p
                    submit()
                } label: {
                    Text(p)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .lineLimit(1)
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 18))
                .disabled(!settings.canRun || pending)
            }
        }
    }

    private var timeOfDayGreeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Hi there"
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // `GlassEffectContainer` batches the assistant-bubble
                // glass surfaces + typing indicator into a single
                // compositor pass — both cheaper and a prerequisite for
                // any future morph between the typing indicator and the
                // assistant's first chunk of streamed text.
                GlassEffectContainer(spacing: 14) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if live.messages.isEmpty {
                            emptyTranscript
                        } else {
                            ForEach(live.messages) { msg in
                                MessageBubble(
                                    message: msg,
                                    glowing: pending
                                        && msg.id == live.messages.last?.id
                                        && msg.role == .assistant
                                ).id(msg.id)
                            }
                        }
                        if pending {
                            TypingIndicator(label: pendingLabel).id("__typing")
                        }
                        if let err = lastError {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onChange(of: live.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: pending) { _, _ in
                scrollToBottom(proxy)
            }
            .onAppear { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                if pending {
                    proxy.scrollTo("__typing", anchor: .bottom)
                } else if let last = live.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyTranscript: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ready when you are.")
                .font(.system(size: 14, weight: .semibold))
            Text("Try: \"how is the semiconductor sector doing?\" · \"compare AAPL "
                 + "and MSFT margins\" · \"screen S&P 500 for P/E < 15 and ROE > 20%\".")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    // MARK: Composer

    /// Composer adapts to its spatial context:
    ///   - Hero mode (empty session): visually heavier — larger font,
    ///     bigger padding, `lineLimit(3...12)` so the empty textarea
    ///     claims real estate the way Claude's landing card does.
    ///   - Inline mode (active conversation): compact bottom strip,
    ///     `lineLimit(1...8)`, same as before — doesn't compete with
    ///     the transcript for vertical attention.
    private var composer: some View {
        let hero = showHero
        let fieldFont: Font = .system(size: hero ? 15 : 13)
        let corner: CGFloat = hero ? 16 : 12
        let vPad: CGFloat = hero ? 18 : 10
        let hPad: CGFloat = hero ? 16 : 12
        let lines: ClosedRange<Int> = hero ? 3...12 : 1...8
        let sendSize: CGFloat = hero ? 30 : 26
        let outerHPad: CGFloat = hero ? 0 : 18

        return VStack(spacing: 8) {
            if !settings.canRun {
                providerHint
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask anything…", text: $draft, axis: .vertical)
                    .lineLimit(lines)
                    .textFieldStyle(.plain)
                    .font(fieldFont)
                    .padding(.horizontal, hPad)
                    .padding(.vertical, vPad)
                    .liquidGlass(cornerRadius: corner)
                    .intelligenceGlow(
                        active: inputFocused || pending,
                        cornerRadius: corner,
                        intensity: pending ? 1.0 : 0.65
                    )
                    .focused($inputFocused)
                    .onSubmit { submit() }

                Button {
                    submit()
                } label: {
                    // Clean filled-circle glyph — the border-beam glow
                    // doesn't read well at this size (the 9-spike
                    // ellipse stack squeezes into a muddle on a
                    // 30 pt circle). The arrow glyph alone is already
                    // a strong "send" signal.
                    Image(systemName: pending
                          ? "stop.circle.fill"
                          : "arrow.up.circle.fill")
                        .font(.system(size: sendSize))
                        .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSubmit)
                .help("Send (⌘⏎)")
            }
            .padding(.horizontal, outerHPad)
            .padding(.bottom, hero ? 0 : 14)
            .padding(.top, hero ? 0 : 4)
        }
    }

    private var canSubmit: Bool {
        !pending
            && settings.canRun
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var providerHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "key")
            Text("Add an Anthropic key or point at a local model in any ticker's "
                 + "AI tab to enable replies.")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Submit

    /// Dispatches one user turn through `ChatAgent` — which means the
    /// model can call `MarketDataTool`, `SocialSentimentTool`, etc.
    /// mid-turn before producing a final reply. We:
    ///
    ///   1. Append the user message to `ChatStore` so the UI updates
    ///      immediately.
    ///   2. Build `[LLMMessage]` from prior messages only (ChatAgent
    ///      re-appends the user turn via its `userMessage` parameter).
    ///   3. Hand the `ChatAgent` the conversation slice and wait for
    ///      its final tool-free reply. Intermediate `tool_use` /
    ///      `tool_result` rounds stay inside the agent's working
    ///      buffer — we don't persist them to `ChatStore`, since the
    ///      UI doesn't render them as discrete messages today.
    ///   4. Wire `onEvent` into `pendingLabel` so the typing indicator
    ///      switches between dots ↔ "calling get_market_data…" as the
    ///      loop runs.
    private func submit() {
        guard canSubmit else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        lastError = nil
        store.append(ChatMessage(role: .user, text: text), to: session.id)
        pending = true
        pendingLabel = "thinking…"

        // Build conversation from EVERY prior message (excluding the
        // one we just appended — ChatAgent will append it again from
        // `userMessage`). Using `dropLast()` is safe because we just
        // appended one message above and `store.append` is synchronous.
        let prior = Array(live.messages.dropLast())
        let history: [LLMMessage] = prior.map {
            LLMMessage(role: $0.role == .assistant ? .assistant : .user,
                       content: $0.text)
        }
        guard let provider = WickerLLM.provider(for: settings) else {
            pending = false
            pendingLabel = nil
            lastError = "No provider configured."
            return
        }
        // ChatAgent uses `deepModel` from the config; the quick model
        // doesn't matter here (no analyst pipeline in chat). Settings'
        // workflowConfig() picks up the right per-provider models
        // automatically.
        let config: TradingFloorConfig = settings.workflowConfig()
        let agent = runtime.makeChatAgent(llm: provider, config: config)
        let sessionID = session.id

        Task {
            var conversation = history
            do {
                let reply = try await agent.respond(
                    to: text,
                    conversation: &conversation,
                    onEvent: { event in
                        Task { @MainActor in
                            handleAgentEvent(event)
                        }
                    })
                await MainActor.run {
                    store.append(ChatMessage(role: .assistant, text: reply),
                                 to: sessionID)
                    pending = false
                    pendingLabel = nil
                }
            } catch {
                await MainActor.run {
                    pending = false
                    pendingLabel = nil
                    lastError = describe(error)
                }
            }
        }
    }

    private func handleAgentEvent(_ event: ChatEvent) {
        switch event {
        case .toolCall(let name, _):
            pendingLabel = "calling \(name)…"
        case .toolResult:
            pendingLabel = "thinking…"
        case .userTurn, .assistantRaw, .finalReply:
            break
        }
    }

    private func describe(_ error: any Error) -> String {
        if let e = error as? LLMError {
            switch e {
            case .transport(let m):   return "Network: \(m)"
            case .http(let s, let b): return "HTTP \(s): \(b.prefix(180))"
            case .decoding(let m):    return "Decoding: \(m)"
            case .empty:              return "Empty response from model."
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Bubbles + typing indicator

private struct MessageBubble: View {
    let message: ChatMessage
    var glowing: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: message.role == .user ? .trailing : .leading,
                   spacing: 3)
            {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background {
                        switch message.role {
                        case .user:
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.accentColor.opacity(0.18))
                        case .assistant:
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .glassEffect(.regular,
                                             in: .rect(cornerRadius: 12))
                        case .system:
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.orange.opacity(0.14))
                        }
                    }
                    .foregroundStyle(textColor)
                    .intelligenceGlow(
                        active: glowing && message.role == .assistant,
                        cornerRadius: 12,
                        intensity: 0.7
                    )
            }
            if message.role != .user { Spacer(minLength: 60) }
        }
    }

    private var label: String {
        switch message.role {
        case .user:      return "YOU"
        case .assistant: return "WICKER"
        case .system:    return "SYSTEM"
        }
    }

    private var textColor: Color {
        message.role == .system ? .orange : .primary
    }
}

/// Pending indicator with optional inline label ("calling
/// get_market_data…", etc). Default dots fill in when `label` is nil
/// or empty — preserves the existing "I'm processing" affordance.
private struct TypingIndicator: View {
    let label: String?
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common)
        .autoconnect()

    init(label: String? = nil) { self.label = label }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary.opacity(i == phase ? 0.85 : 0.35))
                        .frame(width: 6, height: 6)
                }
            }
            if let label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospaced(label.contains("("))   // tool names look better mono
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .liquidGlass(cornerRadius: 12)
        .intelligenceGlow(
            active: true,
            cornerRadius: 12,
            intensity: 0.85
        )
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

// MARK: - Provider factory

/// Pulls the right `LLMProvider` + model name out of `AgentSettings`
/// per the user's `providerKind` selection. Built fresh per turn so a
/// settings change between turns (key paste, provider swap) takes
/// effect immediately.
///
/// Dispatch follows the same enum switch as `DeskRunner`:
///   - `.server` → returns nil for chat (server-side `/chat` endpoint
///     is the SaaS-tier work item, not built yet — workflow agent
///     still works via `ServerReportClient`)
///   - `.anthropic` → `AnthropicProvider`
///   - everything else → `OpenAICompatibleProvider`, baseURL +
///     apiKey from settings
enum WickerLLM {
    static let systemPrompt: String = """
    You are Wicker — Wick's careful, concise market analyst.
    The user is reasoning about stocks, ETFs, indices, sectors, and macro.
    You can: discuss individual tickers, compare them, walk through index
    or sector dynamics, suggest screening criteria, and reason about
    economic context. You don't have live market-data tools yet; when a
    question needs real-time prices or fundamentals, say what you'd need
    and how you'd interpret it rather than inventing numbers. Be honest
    about uncertainty. Never give personalised investment advice — give
    analysis. Use Markdown sparingly; short paragraphs and tight bullets
    beat long prose.
    """

    @MainActor
    static func provider(for settings: AgentSettings) -> (any LLMProvider)? {
        switch settings.providerKind {
        case .server:
            // SaaS-tier chat (server-side `/chat`) is a future endpoint —
            // for v1, server mode only powers the workflow agent. Chat
            // shows the "no provider" hint until that lands.
            return nil
        case .anthropic:
            guard !settings.currentAPIKey.isEmpty else { return nil }
            let baseURL = URL(string: settings.byoBaseURL)
                ?? URL(string: ProviderKind.anthropic.defaultBaseURL)!
            return AnthropicProvider(apiKey: settings.currentAPIKey,
                                      baseURL: baseURL)
        default:
            // OpenAI-compatible umbrella: 9 hosted clouds + Custom +
            // Ollama. Ollama and self-hosted proxies skip auth.
            guard let url = URL(string: settings.byoBaseURL) else {
                return nil
            }
            let key: String? = settings.providerKind.requiresAPIKey
                ? (settings.currentAPIKey.isEmpty ? nil : settings.currentAPIKey)
                : nil
            if settings.providerKind.requiresAPIKey, key == nil { return nil }
            return OpenAICompatibleProvider(baseURL: url, apiKey: key)
        }
    }

    @MainActor
    static func model(for settings: AgentSettings) -> String {
        settings.deepModel
    }
}
