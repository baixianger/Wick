import SwiftUI
import Combine
import CoreCharts
import MarkdownUI
import TradingFloor
import UniformTypeIdentifiers
#if canImport(WebKit)
import WebKit
#endif

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
    @Environment(AgentRuntime.self) private var runtime
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
    /// History drawer is closed by default — the workspace centres on
    /// the current conversation, à la Claude.app's recent macOS
    /// redesign. User toggles via the `sidebar.trailing` icon in the
    /// top-right of the conversation pane or ⌘⇧H.
    @State private var showHistoryDrawer: Bool = false
    /// User pin for the right-side agent-browser panel. Hoisted here (out
    /// of `WickerBrowserPanel`) so the reveal condition in `body` survives
    /// the agent going idle — once pinned, the panel stays mounted and
    /// open until the user collapses it, instead of unmounting and losing
    /// per-view state the moment `isAgentBrowsing` flips false.
    @State private var browserPinnedOpen: Bool = false

    /// User-draggable cap of the CHAT content column. The browser panel is now a
    /// FIXED width set in Settings (`settings.wickerBrowserWidth`) and is NOT
    /// resized by dragging; instead the divider drags THIS — the chat content
    /// column's max width. When the browser opens the chat pane narrows and the
    /// centred capped content shrinks to fit. Hoisted so it survives the panel
    /// mounting / unmounting.
    @State private var chatColumnWidth: CGFloat = 760
    /// In-drag baseline so the gesture is relative to where the divider was
    /// when the drag began, not absolute pointer position (avoids a jump on
    /// grab). nil when no drag is in flight.
    @State private var chatDragStartWidth: CGFloat?

    /// Clamp for the chat content column. Lower bound keeps bubbles readable;
    /// upper bound keeps a comfortable reading measure on a wide pane.
    private let chatColumnRange: ClosedRange<CGFloat> = 460...1000

    /// True while a `web.*` tool is mid-flight (macOS 26 + flag on +
    /// a live `BrowserSessionManager`). Drives the right-region hand-off:
    /// when this flips true we collapse the history drawer. Returns false
    /// in every gated-off / pre-26 path so the legacy layout is untouched.
    private var agentBrowserActive: Bool {
        if #available(macOS 26.0, *), settings.enableWickerBrowser,
           let manager = runtime.browserSession as? BrowserSessionManager {
            return manager.isAgentBrowsing
        }
        return false
    }

    /// Whether the right-side browser panel should occupy the trailing
    /// region: the agent is actively browsing, OR the user has pinned it
    /// open to finish a login / inspect a result.
    @available(macOS 26.0, *)
    private func browserPanelRevealed(_ manager: BrowserSessionManager) -> Bool {
        manager.isAgentBrowsing || browserPinnedOpen
    }

    var body: some View {
        // Is the browser panel occupying the trailing region right now? When it
        // is, the chat becomes a fixed (draggable) width and the browser fills
        // the rest; when it isn't, the chat fills the whole pane.
        let browserShown: Bool = {
            if #available(macOS 26.0, *), settings.enableWickerBrowser,
               let manager = runtime.browserSession as? BrowserSessionManager {
                return browserPanelRevealed(manager)
            }
            return false
        }()
        return GeometryReader { geo in
        // Clamp the Settings-driven fixed browser width against the window so the
        // chat always keeps a usable minimum: a wide setting on a narrow window
        // auto-shrinks the browser rather than squeezing the chat away. `minChat`
        // is the floor for the chat region; `11` is the resize-handle width.
        let minChat: CGFloat = 360
        let browserW = min(CGFloat(settings.wickerBrowserWidth),
                           max(minChat, geo.size.width - minChat - 11))
        HStack(spacing: 0) {
            conversationPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    // Liquid Glass capsule around the action cluster
                    // means message bubbles scrolling past it look
                    // visually separated (material blur), instead of
                    // appearing to crash into the icons. Matches the
                    // Claude.app / Apple Messages pattern — icons sit
                    // in a clear "header zone" with their own surface,
                    // chat fills the pane underneath.
                    headerActions
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .liquidGlass(cornerRadius: 14)
                        .padding(.top, 12)
                        .padding(.trailing, 14)
                }
            // Right region is shared: the live agent browser (Option A
            // slide-in) takes priority over the history drawer. Both are
            // 280–360pt trailing panels; showing both at once would crush
            // the conversation, so the browser auto-collapses the history
            // drawer when it reveals (see `.onChange` below).
            if #available(macOS 26.0, *), settings.enableWickerBrowser,
               let manager = runtime.browserSession as? BrowserSessionManager,
               browserPanelRevealed(manager)
            {
                // Split handle between chat and browser. The browser is FIXED
                // (its width comes from Settings, clamped above); dragging the
                // handle adjusts the CHAT content column cap (`chatColumnWidth`),
                // not the browser.
                browserResizeHandle
                // Browser is the FIXED-width side (width from Settings, clamped
                // against the window); the chat absorbs the rest but centres its
                // capped content so no dead gap forms.
                WickerBrowserPanel(manager: manager, pinnedOpen: $browserPinnedOpen)
                    .frame(width: browserW)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if showHistoryDrawer {
                Divider()
                sessionDrawer
                    .frame(width: 280)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // Fill the GeometryReader so layout is unchanged aside from the
        // clamped-width logic above.
        .frame(width: geo.size.width, height: geo.size.height)
        // Animate the right-side reveal when the agent starts/stops
        // browsing (that flip comes from the manager, outside any
        // `withAnimation` block, so the transition needs this value-keyed
        // animation to slide rather than pop).
        .animation(.snappy(duration: 0.25), value: agentBrowserActive)
        .background(appleBackground(for: colorScheme))
        .onChange(of: agentBrowserActive) { _, active in
            if active {
                // AUTO-PIN the panel the instant the agent starts browsing, so
                // it STAYS open after the (often sub-second) tool call finishes
                // — otherwise the page just flashes by and the user can't log
                // in / watch / take over. They dismiss it with the panel's pin
                // toggle. Also hand the right region to the browser by
                // collapsing the history drawer (it still toggles when closed).
                withAnimation(.snappy(duration: 0.22)) {
                    browserPinnedOpen = true
                    showHistoryDrawer = false
                }
            }
        }
        .onAppear { ensureSession() }
        .onChange(of: store.sessions.count) { _, _ in ensureSession() }
        .alert(L("Rename session", "重命名会话"),
               isPresented: Binding(
                get: { renamingSessionID != nil },
                set: { if !$0 { renamingSessionID = nil } }
               ))
        {
            TextField(L("Title", "标题"), text: $renameDraft)
            Button(L("Cancel", "取消"), role: .cancel) { renamingSessionID = nil }
            Button(L("Rename", "重命名")) { commitRename() }
        }
        }
    }

    /// Split handle between the conversation pane and the (fixed) browser.
    /// A crisp 1pt vertical hairline sits centred in an 11pt transparent hit
    /// strip (easy to grab); the pointer becomes the `resizeLeftRight` cursor on
    /// hover. The browser is FIXED (its width comes from Settings), so dragging
    /// adjusts the CHAT content column cap instead: drag RIGHT → wider chat
    /// column, LEFT → narrower — `chatColumnWidth += translation.x`.
    @available(macOS 26.0, *)
    private var browserResizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 11)
            .frame(maxHeight: .infinity)
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = chatDragStartWidth ?? chatColumnWidth
                        if chatDragStartWidth == nil { chatDragStartWidth = base }
                        // The handle sits to the LEFT of the fixed browser, so
                        // dragging it RIGHT widens the chat content column.
                        let proposed = base + value.translation.width
                        chatColumnWidth = min(max(proposed, chatColumnRange.lowerBound),
                                              chatColumnRange.upperBound)
                    }
                    .onEnded { _ in chatDragStartWidth = nil }
            )
    }

    /// Two-icon control cluster in the top-right of the conversation
    /// pane: new chat + drawer toggle. Kept tiny + iconic to match
    /// the "right pane is just chat" rule — no labels, no chrome
    /// around the chat content itself.
    private var headerActions: some View {
        HStack(spacing: 14) {
            Button {
                store.newSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help(L("New chat (⌘N)", "新建对话 (⌘N)"))
            .accessibilityLabel("New chat")
            .accessibilityIdentifier("WickerNewChatButton")

            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    showHistoryDrawer.toggle()
                }
            } label: {
                Image(systemName: showHistoryDrawer
                      ? "sidebar.trailing"
                      : "sidebar.trailing")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(showHistoryDrawer
                                      ? AnyShapeStyle(Color.accentColor)
                                      : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .help(showHistoryDrawer ? L("Hide history (⌘⇧H)", "隐藏历史 (⌘⇧H)") : L("Show history (⌘⇧H)", "显示历史 (⌘⇧H)"))
            .accessibilityLabel(showHistoryDrawer ? "Hide history" : "Show history")
            .accessibilityIdentifier("WickerHistoryToggle")
        }
    }

    /// Right-side history drawer. Reuses the existing `sessionList`
    /// (now standalone, no longer wrapped in a "column" with its own
    /// header — the headerActions on the conversation pane carry the
    /// new-chat button instead).
    private var sessionDrawer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(L("History", "历史"))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(store.sessions.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)
            if store.sessions.isEmpty {
                emptyColumn
            } else {
                sessionList
            }
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

    // MARK: - History drawer rendering (legacy section column gone)
    // The session list view itself is unchanged — it's now hosted
    // inside `sessionDrawer` above rather than a permanently-visible
    // column.

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
                                    Label(L("Rename…", "重命名…"), systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    store.delete(id: session.id)
                                } label: {
                                    Label(L("Delete", "删除"), systemImage: "trash")
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
            ConversationView(store: store, session: session,
                             contentMaxWidth: chatColumnWidth)
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
        if !today.isEmpty     { groups.append(.init(label: L("TODAY", "今天"), sessions: today)) }
        if !yesterday.isEmpty { groups.append(.init(label: L("YESTERDAY", "昨天"), sessions: yesterday)) }
        if !thisWeek.isEmpty  { groups.append(.init(label: L("THIS WEEK", "本周"), sessions: thisWeek)) }
        if !earlier.isEmpty   { groups.append(.init(label: L("EARLIER", "更早"), sessions: earlier)) }
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
                            .foregroundStyle(Color.accentColor)
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
            return L("You: ", "你：") + lastUser.text.replacingOccurrences(of: "\n", with: " ")
        }
        return L("No messages yet", "暂无消息")
    }

    private var timeStamp: String {
        let cal = Calendar.current
        let now = Date.now
        if cal.isDate(session.updatedAt, inSameDayAs: now) {
            return session.updatedAt.formatted(date: .omitted, time: .shortened)
        }
        let yesterday = cal.date(byAdding: .day, value: -1, to: now) ?? now
        if cal.isDate(session.updatedAt, inSameDayAs: yesterday) {
            return L("Yesterday", "昨天")
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
    /// Max width of the chat content column. Driven by `WickerView`'s
    /// draggable divider; the centred capped content shrinks to fit when the
    /// chat pane narrows (browser open). Defaults to the prior hardcoded cap.
    var contentMaxWidth: CGFloat = 820

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

    // General attachment state (Phase B). The composer accepts images +
    // PDF / CSV / Excel / text via a 📎 multi-select picker and drag-drop;
    // each file is run through `AttachmentExtractor` (images → downscaled
    // base64 for vision; docs → extracted text) and parked as a chip in
    // `pendingAttachments` until the user sends. On send they ride on the
    // user `ChatMessage` — images become `LLMImage` parts, docs are folded
    // into the prompt text. Decoupled from the portfolio: Wicker reads the
    // content and composes behaviour with its existing tools.
    @State private var showFilePicker: Bool = false
    @State private var pendingAttachments: [ChatAttachment] = []
    /// Count of in-flight extractions — drives the spinner; >0 ⇒ busy.
    @State private var extractingCount: Int = 0
    @State private var attachmentError: String?
    @State private var isDropTargeted: Bool = false

    private var isExtracting: Bool { extractingCount > 0 }

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
        // The live agent-browser panel used to mount here, at the bottom
        // of the conversation pane. It now lives at `WickerView.body` as a
        // RIGHT-side slide-in (Option A) so it shares the right region with
        // the history drawer instead of stacking under the composer.
        Group {
            if showHero {
                heroLayout
            } else {
                VStack(spacing: 0) {
                    transcript
                    composer
                }
            }
        }
        // Cap the chat to a comfortable reading column and CENTRE it. On a wide
        // pane (and especially with the fixed browser open beside it) this stops
        // the narrow bubbles from leaving a lopsided dead gap on the right —
        // symmetric margins instead, the Claude / ChatGPT layout. The cap is
        // dynamic — dragging the chat↔browser divider drives it.
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        // Auto-continue: if the session opens with an unanswered user
        // turn (typical when the FloatingWickerComposer kicked off a
        // chat from outside Wicker), dispatch the agent loop on
        // appear. Also runs after a session swap, so resuming a chat
        // that ended on the user's side just continues. Guarded by
        // `pending` so a re-render mid-dispatch doesn't double-fire.
        .onAppear { autoContinueIfNeeded() }
        .onChange(of: session.id) { _, _ in autoContinueIfNeeded() }
    }

    /// Look at the live session's tail: if the last message is a
    /// user turn (no assistant reply after it) and we're not already
    /// processing, kick off `submit()` on that text. This is the
    /// hand-off path from the floating composer.
    private func autoContinueIfNeeded() {
        guard !pending, lastError == nil else { return }
        let msgs = live.messages
        guard let last = msgs.last, last.role == .user else { return }
        // Lift the user's text into `draft` so `submit()` (which
        // reads from `draft`) picks it up, but DON'T re-append the
        // user turn — `submit()` would otherwise duplicate it.
        // Easiest way: temporarily set draft, clear it, then run
        // the dispatch path directly so the user message stays the
        // one ChatStore already has.
        dispatchExistingUserTurn(message: last)
    }

    /// Same body as `submit()` minus the user-message append + draft
    /// reset. Used by `autoContinueIfNeeded` to drive the LLM call
    /// against a user message that's already in the store.
    private func dispatchExistingUserTurn(message: ChatMessage) {
        lastError = nil
        pending = true
        pendingLabel = L("thinking…", "思考中…")
        let text = message.text
        let prior = Array(live.messages.dropLast())
        let history: [LLMMessage] = prior.map(Self.llmMessage(from:))
        guard let provider = WickerLLM.provider(for: settings) else {
            pending = false
            pendingLabel = nil
            lastError = L("No provider configured.", "未配置服务商。")
            return
        }
        let config: TradingFloorConfig = settings.workflowConfig()
        let agent = runtime.makeChatAgent(llm: provider, config: config)
        let sessionID = session.id
        let folded = Self.foldedContent(text: text, attachments: message.attachments)
        let images = Self.llmImages(from: message.attachments)
        Task {
            var conversation = history
            do {
                let reply = try await agent.respond(
                    to: folded,
                    images: images,
                    conversation: &conversation,
                    onEvent: { event in
                        Task { @MainActor in handleAgentEvent(event) }
                    })
                await MainActor.run {
                    store.append(ChatMessage(role: .assistant, text: reply),
                                 to: sessionID)
                    pending = false
                    pendingLabel = nil
                    titleSessionIfNeeded(userText: text,
                                          assistantText: reply,
                                          sessionID: sessionID)
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

    /// Fire `SessionTitler` in the background once the first
    /// complete turn (1 user + 1 assistant) lands. Cheap lite-model
    /// call; failure silently leaves the heuristic-truncated title
    /// in place. Skipped if the user has manually renamed.
    private func titleSessionIfNeeded(userText: String,
                                       assistantText: String,
                                       sessionID: UUID)
    {
        guard let s = store.session(for: sessionID) else { return }
        let userTurns = s.messages.filter { $0.role == .user }.count
        let assistantTurns = s.messages.filter { $0.role == .assistant }.count
        guard userTurns == 1, assistantTurns == 1 else { return }
        let autoHeuristic = String(
            (userText.split(whereSeparator: \.isNewline).first
                .map(String.init) ?? userText)
                .trimmingCharacters(in: .whitespaces)
                .prefix(40)
        )
        // Skip if the user (or some other path) has already
        // overridden the auto-title — preserve user intent.
        guard s.title == autoHeuristic || s.title == "New chat" else { return }
        Task { @MainActor in
            if let title = await SessionTitler.makeTitle(
                userText: userText,
                assistantText: assistantText,
                settings: settings)
            {
                store.rename(id: sessionID, to: title)
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

    /// Tap a hint to one-shot the question. Rendered as plain
    /// minimal text — glass-capsule chips here read as too much UI
    /// chrome ("用力过猛") on an otherwise quiet hero. Dot
    /// separators give the row visual rhythm without locking it
    /// into containers.
    private var heroSuggestions: some View {
        let prompts = [
            L("How is NVDA doing today?", "NVDA 今天表现如何？"),
            L("Compare AAPL and MSFT margins", "对比 AAPL 与 MSFT 的利润率"),
            L("Screen S&P 500 for P/E < 15", "筛选标普 500 中市盈率 < 15 的股票"),
            L("What's the macro setup for tech?", "科技板块的宏观环境如何？"),
        ]
        return HStack(spacing: 14) {
            ForEach(Array(prompts.enumerated()), id: \.offset) { idx, p in
                if idx > 0 {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    draft = p
                    submit()
                } label: {
                    Text(p)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(!settings.canRun || pending)
            }
        }
    }

    private var timeOfDayGreeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12:  return L("Good morning", "早上好")
        case 12..<17: return L("Good afternoon", "下午好")
        case 17..<22: return L("Good evening", "晚上好")
        default:      return L("Hi there", "你好")
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
                                        && msg.role == .assistant,
                                    mentionedTickers: mentionedTickers(in: msg)
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
                    // Top inset = headerActions overlay height
                    // (~32pt capsule + 12pt top padding ≈ 50pt) so a
                    // fresh message bubble starts below the action
                    // cluster rather than under it.
                    .padding(.top, 56)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Soft top edge: instead of bubbles hard-cutting at the top of the
            // scroll view, fade the content to transparent over the top ~64pt so
            // text dissolves gently as it scrolls up (and tucks softly behind the
            // headerActions capsule). A fixed-height fade band over a fully-opaque
            // remainder keeps the fade a constant thickness regardless of panel
            // height; masking to transparency reveals the real window background
            // underneath, so it reads as a true fade-out, not a coloured overlay.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.35), .black],
                        startPoint: .top, endPoint: .bottom)
                        .frame(height: 64)
                    Rectangle().fill(.black)
                }
                .ignoresSafeArea()
            )
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
            Text(L("Ready when you are.", "随时为你效劳。"))
                .font(.system(size: 14, weight: .semibold))
            Text(L("Try: \"how is the semiconductor sector doing?\" · \"compare AAPL "
                 + "and MSFT margins\" · \"screen S&P 500 for P/E < 15 and ROE > 20%\".",
                 "试试：「半导体板块表现如何？」·「对比 AAPL 与 MSFT 的利润率」·「筛选标普 500 中市盈率 < 15 且 ROE > 20% 的股票」。"))
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
            if !pendingAttachments.isEmpty || isExtracting {
                attachmentChipsRow(outerHPad: outerHPad)
            }
            if let err = attachmentError {
                importErrorBanner(err)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    showFilePicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: hero ? 17 : 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, hero ? 4 : 2)
                }
                .buttonStyle(.plain)
                .disabled(!settings.canRun)
                .help(L("Attach images or documents (PDF / CSV / Excel / text)", "添加图片或文档（PDF / CSV / Excel / 文本）"))
                .accessibilityLabel("Attach file")
                .accessibilityIdentifier("WickerAttachButton")

                TextField(L("Ask anything…", "随便问点什么…"), text: $draft, axis: .vertical)
                    .lineLimit(lines)
                    .textFieldStyle(.plain)
                    .font(fieldFont)
                    .padding(.horizontal, hPad)
                    .padding(.vertical, vPad)
                    .liquidGlass(cornerRadius: corner)
                    .intelligenceGlow(
                        // Always-on glow — Wicker is "ambiently alive".
                        // Intensity varies with state so a focused
                        // or thinking composer still feels louder
                        // than an idle one, without the effect ever
                        // turning off completely.
                        active: true,
                        cornerRadius: corner,
                        intensity: pending ? 1.0
                            : (inputFocused ? 0.85 : 0.55)
                    )
                    .overlay(dropTargetOverlay(cornerRadius: corner))
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
                .help(L("Send (⌘⏎)", "发送 (⌘⏎)"))
                .accessibilityLabel(pending ? "Stop generating" : "Send message")
                .accessibilityIdentifier("WickerSendButton")
            }
            .padding(.horizontal, outerHPad)
            .padding(.bottom, hero ? 0 : 14)
            .padding(.top, hero ? 0 : 4)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: Self.attachableTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls { startExtraction(from: url, fromPicker: true) }
            case .failure(let err):
                attachmentError = err.localizedDescription
            }
        }
    }

    /// UTTypes the composer accepts via drop + picker: images + the document
    /// formats the extractor can read. `.spreadsheet` covers `.xlsx`; the
    /// explicit `xlsx` filename type is added so the picker shows it even when
    /// the system maps the extension loosely.
    static let attachableTypes: [UTType] = {
        var types: [UTType] = [
            .image,
            .pdf,
            .commaSeparatedText,
            .plainText,
            .text,
            .spreadsheet,
        ]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        return types
    }()

    // MARK: Attachment chips

    /// Horizontal row of attachment chips above the text field. Image chips
    /// show a thumbnail; doc chips show an SF Symbol + truncated filename.
    /// Each has a remove (×). A trailing spinner appears while extraction runs.
    @ViewBuilder
    private func attachmentChipsRow(outerHPad: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in
                    AttachmentChip(attachment: att) {
                        pendingAttachments.removeAll { $0.id == att.id }
                    }
                }
                if isExtracting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("Reading…", "读取中…")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, outerHPad)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func importErrorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .lineLimit(3)
            Spacer()
            Button {
                attachmentError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    /// Highlighted ring shown around the textfield while a drag is
    /// hovering over the composer. Pure feedback — the actual drop
    /// handler lives on the outer VStack so the user can drop
    /// anywhere in the composer strip.
    @ViewBuilder
    private func dropTargetOverlay(cornerRadius: CGFloat) -> some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )
                .allowsHitTesting(false)
        }
    }

    /// Pulls the first file URL out of the drop, validates the
    /// extension, and kicks off LLM extraction.
    ///
    /// Uses `loadFileRepresentation` instead of `loadObject(ofClass:
    /// URL.self)` because the dropped URL on a sandboxed (MAS) build
    /// is only valid INSIDE the completion handler — the security-
    /// scoped bookmark isn't preserved across hops. We copy the file
    /// to a sandbox-writable temp path while we still have access,
    /// then dispatch the extractor against the copy.
    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // Prefer the canonical UTI for file URLs; falls back to any
        // available type identifier the system advertises.
        let typeID = provider.registeredTypeIdentifiers.first {
            $0 == "public.file-url" || $0 == "public.url" || $0.hasPrefix("public.")
        } ?? (provider.registeredTypeIdentifiers.first ?? "public.file-url")

        _ = provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
            guard let url else { return }
            // `url` is valid only for the duration of this callback —
            // copy to a sandbox-writable temp path before returning.
            let tmpBase = FileManager.default.temporaryDirectory
                .appendingPathComponent("WickImports", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: tmpBase, withIntermediateDirectories: true)
            let copy = tmpBase.appendingPathComponent(
                "\(UUID().uuidString)-\(url.lastPathComponent)")
            do {
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                return
            }
            Task { @MainActor in
                // Dropped copies live in our temp dir — no security scope hop.
                startExtraction(from: copy, fromPicker: false)
            }
        }
        return true
    }

    /// Run a file through `AttachmentExtractor` off the main actor and park the
    /// resulting `ChatAttachment` chip. `fromPicker` selections need a
    /// security-scoped access hop (sandboxed MAS build); dropped copies (which
    /// already live in our temp dir) don't.
    private func startExtraction(from url: URL, fromPicker: Bool) {
        attachmentError = nil
        extractingCount += 1
        let filename = url.lastPathComponent
        let needsScope = fromPicker && url.startAccessingSecurityScopedResource()
        Task {
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let attachment = try await AttachmentExtractor.extract(url: url)
                await MainActor.run {
                    extractingCount = max(0, extractingCount - 1)
                    pendingAttachments.append(attachment)
                }
            } catch {
                await MainActor.run {
                    extractingCount = max(0, extractingCount - 1)
                    attachmentError = (error as? LocalizedError)?.errorDescription
                        ?? L("Couldn't read \(filename): \(error.localizedDescription)",
                             "无法读取 \(filename)：\(error.localizedDescription)")
                }
            }
        }
    }

    private var canSubmit: Bool {
        !pending
            && !isExtracting
            && settings.canRun
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingAttachments.isEmpty)
    }

    private var providerHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "key")
            Text(L("Add an Anthropic key or point at a local model in any ticker's "
                 + "AI tab to enable replies.",
                 "在任意标的的 AI 标签页中添加 Anthropic 密钥或指向本地模型即可启用回复。"))
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
        let attachments = pendingAttachments
        draft = ""
        pendingAttachments = []
        attachmentError = nil
        lastError = nil
        store.append(ChatMessage(role: .user, text: text, attachments: attachments),
                     to: session.id)
        pending = true
        pendingLabel = L("thinking…", "思考中…")

        // Build conversation from EVERY prior message (excluding the
        // one we just appended — ChatAgent will append it again from
        // `userMessage`). Using `dropLast()` is safe because we just
        // appended one message above and `store.append` is synchronous.
        let prior = Array(live.messages.dropLast())
        let history: [LLMMessage] = prior.map(Self.llmMessage(from:))
        guard let provider = WickerLLM.provider(for: settings) else {
            pending = false
            pendingLabel = nil
            lastError = L("No provider configured.", "未配置服务商。")
            return
        }
        // ChatAgent uses `deepModel` from the config; the quick model
        // doesn't matter here (no analyst pipeline in chat). Settings'
        // workflowConfig() picks up the right per-provider models
        // automatically.
        let config: TradingFloorConfig = settings.workflowConfig()
        let agent = runtime.makeChatAgent(llm: provider, config: config)
        let sessionID = session.id
        // Fold doc attachments into the prompt; images ride as vision parts.
        let folded = Self.foldedContent(text: text, attachments: attachments)
        let images = Self.llmImages(from: attachments)

        Task {
            var conversation = history
            do {
                let reply = try await agent.respond(
                    to: folded,
                    images: images,
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
                    titleSessionIfNeeded(userText: text,
                                          assistantText: reply,
                                          sessionID: sessionID)
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

    // MARK: ChatMessage → LLMMessage seam

    /// Build the `[LLMImage]` parts for a user turn from its image
    /// attachments. Empty for assistant turns and doc-only turns.
    static func llmImages(from attachments: [ChatAttachment]) -> [LLMImage] {
        attachments.compactMap { att in
            guard att.isImage, let b64 = att.imageBase64, let mime = att.mimeType
            else { return nil }
            return LLMImage(mimeType: mime, base64: b64)
        }
    }

    /// Fold document attachments' extracted text into the message content,
    /// each in a clearly-delimited `[附件 …]` block so the model knows what it
    /// is reading and where each file begins/ends. Images are NOT folded —
    /// they ride as vision parts via `llmImages`.
    static func foldedContent(text: String, attachments: [ChatAttachment]) -> String {
        let docs = attachments.filter { !$0.isImage }
        guard !docs.isEmpty else { return text }
        var out = text
        for doc in docs {
            let body = doc.extractedText ?? ""
            out += "\n\n[附件 \(doc.filename)]\n\(body)\n[/附件]"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reconstruct an `LLMMessage` for a prior conversation turn — folds its
    /// doc text and re-attaches its images so history sent on later turns
    /// stays multimodal-consistent with how it was originally sent.
    static func llmMessage(from message: ChatMessage) -> LLMMessage {
        let role: LLMMessage.Role = message.role == .assistant ? .assistant : .user
        let content = foldedContent(text: message.text, attachments: message.attachments)
        let images = llmImages(from: message.attachments)
        return LLMMessage(role: role, content: content, images: images)
    }

    private func handleAgentEvent(_ event: ChatEvent) {
        switch event {
        case .toolCall(let name, _):
            // `web.*` tool calls (navigate / read / click / type …) drive
            // the live agent browser — surface them as a friendly
            // "Browsing" label with a globe glyph rather than the raw tool
            // name, matching the right-side browser panel's affordance.
            if name.hasPrefix("web.") {
                let action = name.dropFirst("web.".count)
                pendingLabel = L("🌐 Browsing: \(action.isEmpty ? name : String(action))…",
                                 "🌐 浏览中：\(action.isEmpty ? name : String(action))…")
            } else {
                pendingLabel = L("calling \(name)…", "调用 \(name)…")
            }
        case .toolResult:
            pendingLabel = L("thinking…", "思考中…")
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

    // MARK: - Ticker mention detection

    /// Symbols Wicker mentioned in this message that match a ticker we
    /// know about. Bounded set so we don't try to chart "AI", "OK",
    /// "USA", etc. — only show chips for things actually in the
    /// user's sample / custom watchlist.
    private static let knownSymbols: Set<String> = Set(
        Ticker.samples.map(\.symbol)
    )

    /// Cheap regex pass: 1-5 char uppercase words (the standard
    /// ticker shape). Filter against `knownSymbols`. Deduplicate
    /// while preserving order so the chip row matches the order of
    /// first mention.
    private func mentionedTickers(in message: ChatMessage) -> [String] {
        guard message.role == .assistant else { return [] }
        let text = message.text
        var seen = Set<String>()
        var ordered: [String] = []
        // `\$?[A-Z][A-Z.]{0,4}\b` — optional leading $, then 1-5
        // uppercase letters or dots (BRK.B style). The leading word
        // boundary catches "AAPL stock" but also matches mid-sentence
        // tickers without missing them.
        let pattern = #"\$?[A-Z][A-Z.]{0,4}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let m = match,
                  let r = Range(m.range, in: text) else { return }
            var sym = String(text[r])
            if sym.hasPrefix("$") { sym.removeFirst() }
            if Self.knownSymbols.contains(sym), !seen.contains(sym) {
                seen.insert(sym)
                ordered.append(sym)
            }
        }
        return ordered
    }
}

// MARK: - Bubbles + typing indicator

/// Document-waterfall message view (borrowed from `clawbox`'s chat
/// surface). The old bubble layout treated the assistant like an IM
/// reply, but agent output is multi-paragraph long-form — bubbles
/// chop that into walls of cramped inline text. Layout per role:
///
///   - **assistant** → full-width Markdown rendered in flow (no
///     background, no padding wrapper). Reads like a document.
///   - **user** → right-aligned card with subtle fill (short input
///     benefits from a visual boundary).
///   - **system** → centered capsule pill (auxiliary, low weight).
///
/// `glowing == true` means this is the streaming message — we skip
/// `StableMarkdownView`'s equatable cache (content changes per token)
/// and append an animated dot trio underneath.
/// A compact chip representing one attachment. Image attachments show a small
/// thumbnail; documents show an SF Symbol + truncated filename. The composer
/// variant carries a remove (×); the transcript variant (`onRemove == nil`) is
/// read-only.
private struct AttachmentChip: View {
    let attachment: ChatAttachment
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            if attachment.isImage, let image = thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: attachment.symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            Text(attachment.filename)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.filename)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    /// Decode the stored base64 into an NSImage for the thumbnail. Cheap — the
    /// image was already downscaled to ≤1568px on extraction.
    private var thumbnail: NSImage? {
        guard attachment.isImage,
              let b64 = attachment.imageBase64,
              let data = Data(base64Encoded: b64)
        else { return nil }
        return NSImage(data: data)
    }
}

/// Read-only wrapping row of attachment chips shown inside a user transcript
/// bubble. Wraps to multiple lines when the bubble is narrow.
private struct FlowAttachmentRow: View {
    let attachments: [ChatAttachment]
    var body: some View {
        ChipFlowLayout(spacing: 6) {
            ForEach(attachments) { att in
                AttachmentChip(attachment: att)
            }
        }
    }
}

/// Tiny flow layout: lays children left-to-right, wrapping to the next line
/// when the proposed width is exceeded. Enough for chip rows — no fancy
/// alignment, fixed inter-item + line spacing.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxLineWidth: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                maxLineWidth = max(maxLineWidth, x - spacing)
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        maxLineWidth = max(maxLineWidth, x - spacing)
        return CGSize(width: maxLineWidth.isFinite ? maxLineWidth : 0,
                      height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            sv.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                     proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    var glowing: Bool = false
    /// Symbols the message mentions that we recognise — surfaced as
    /// inline sparkline chips beneath the assistant message.
    var mentionedTickers: [String] = []

    var body: some View {
        switch message.role {
        case .system:    systemRow
        case .user:      userCard
        case .assistant: assistantFlow
        }
    }

    // MARK: User

    private var userCard: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("YOU", "你"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                if !message.attachments.isEmpty {
                    FlowAttachmentRow(attachments: message.attachments)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    // MARK: Assistant

    private var assistantFlow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WICKER")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.tertiary)
            // Streaming messages bypass `StableMarkdownView` — its
            // `Equatable` short-circuit would suppress per-token
            // updates. Completed messages do go through it so
            // sibling re-renders (scroll, focus) don't re-parse.
            if glowing {
                Markdown(message.text)
                    .markdownTheme(.wickerWaterfall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StreamingDots()
            } else {
                StableMarkdownView(content: message.text)
            }
            if !mentionedTickers.isEmpty {
                HStack(spacing: 6) {
                    ForEach(mentionedTickers, id: \.self) { symbol in
                        TickerMentionChip(symbol: symbol)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: System

    private var systemRow: some View {
        HStack {
            Spacer()
            Text(message.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
            Spacer()
        }
    }
}

// MARK: - Streaming dots

/// Three-dot pulse animation shown beneath a streaming assistant
/// message. Replaces the bubble-level `intelligenceGlow` — without a
/// bubble there's no rectangle to glow around, but the user still
/// needs feedback that more is coming.
private struct StreamingDots: View {
    @State private var phase: Int = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(phase == i ? 1.0 : 0.3)
            }
        }
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4,
                                          repeats: true) { _ in
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        phase = (phase + 1) % 3
                    }
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

/// Pending indicator with optional inline label ("calling
/// get_market_data…", etc). Default dots fill in when `label` is nil
/// or empty — preserves the existing "I'm processing" affordance.
// MARK: - Ticker mention chip

/// Tiny "the assistant mentioned $XYZ" chip — symbol + a 22-bar
/// SparklineView from CandleKit, pulled live off `LiveDataStore`.
/// Tapping the chip should ideally jump to that ticker's detail
/// (TODO once we have a clean way to plumb the route binding down).
private struct TickerMentionChip: View {
    let symbol: String
    @Environment(LiveDataStore.self) private var store

    var body: some View {
        // Empty fallback if cache miss — the chip just shows the
        // symbol without a sparkline until a background fetch lands.
        let fallback = CandleSeries(symbol: symbol, interval: .d1, candles: [])
        let series = store.series(for: symbol, interval: .d1, fallback: fallback)
        let closes = series.candles.suffix(22).map(\.close)
        let baseline = closes.first
        let last = closes.last ?? baseline ?? 0
        let isUp = (last >= (baseline ?? last))
        let tint: Color = isUp ? .green : .red

        HStack(spacing: 6) {
            Text(symbol)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            if !closes.isEmpty {
                SparklineView(closes: Array(closes),
                              baseline: baseline,
                              style: .area,
                              tint: tint,
                              lineWidth: 1.2)
                    .frame(width: 36, height: 14)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial,
                    in: Capsule())
    }
}

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

// MARK: - Live agent-browser panel

/// The auto-revealing live WebView panel inside Wicker's workspace. It hosts the
/// SAME `agentPage` the `web.*` tools drive (via `BrowserSessionManager`), so
/// every navigation / click / type the agent performs renders here in real time
/// — and because the WebView is interactive, the panel doubles as the
/// login / human-intervention surface (sign in to a gated site, solve a captcha,
/// etc.) without tearing down the page the tools own.
///
/// Reveal logic: the panel slides in from the RIGHT (Option A) whenever
/// `manager.isAgentBrowsing` flips true (a tool is mid-flight), pushing the
/// conversation pane left. When the agent goes idle the panel stays only if the
/// user pinned it (`pinnedOpen`) — otherwise the caller's reveal condition drops
/// it and it slides back out. The pin is owned by `WickerView` and passed in as
/// a binding so that pinned state outlives the agent's idle/active flips (the
/// view itself unmounts when unpinned + idle). Hosted only under
/// `#if available(macOS 26)` + the opt-in flag (the caller gates both).
@available(macOS 26.0, *)
private struct WickerBrowserPanel: View {
    let manager: BrowserSessionManager
    /// User pin, owned by `WickerView`. Once set, the panel stays open even
    /// after the agent goes idle, so the user can finish a login / inspect the
    /// result. Toggling it off while idle collapses the panel out of the right
    /// region entirely (the caller stops mounting it).
    @Binding var pinnedOpen: Bool

    /// Address-bar text. Locally owned (the user types into it) but kept in lock-
    /// step with `manager.agentCurrentURL` so it reflects wherever the SHARED
    /// `agentPage` actually is — whether the user typed it or the agent navigated
    /// there. Seeded on appear and re-synced via `.onChange` below.
    @State private var urlText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            header
            Divider()
            #if canImport(WebKit)
            // Host the ACTIVE tab's page; `activeTabID` is observable, so switching
            // tabs re-renders this and swaps the displayed page.
            WebView(manager.activePage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(manager.activeTabID)
            #endif
        }
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    /// Horizontal strip of tab chips above the address bar, one per open tab,
    /// plus a trailing `+` to open a new blank tab. Stays clean with a single tab
    /// (one chip + `+`). Active chip is accent-tinted; tapping a chip switches,
    /// the small `xmark` closes. Mirrors the address-bar's liquid-glass treatment.
    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(manager.listTabs(), id: \.id) { tab in
                    tabChip(index: tab.index,
                            id: tab.id,
                            title: tab.title,
                            url: tab.url,
                            isActive: tab.isActive)
                }
                Button {
                    Task { _ = await manager.newTab(url: nil) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .liquidGlass(cornerRadius: 8)
                .help(L("New tab", "新标签页"))
                .accessibilityIdentifier("WickerBrowserNewTab")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    /// One tab chip: title-or-host truncated, accent-tinted when active, with a
    /// small close button. Tap switches; the `xmark` closes.
    private func tabChip(index: Int,
                         id: UUID,
                         title: String,
                         url: String,
                         isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Text(Self.chipLabel(title: title, url: url))
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                // Safari-style: the active tab reads in primary ink on a milky
                // raised chip; inactive tabs are secondary grey on the bar. NO
                // accent colour — that's the tint that turned blue AND dimmed
                // when the window lost focus. Materials/semantic greys stay
                // consistent focused vs. unfocused.
                .foregroundStyle(isActive ? AnyShapeStyle(.primary)
                                          : AnyShapeStyle(.secondary))
            Button {
                Task { _ = await manager.closeTab(ref: id.uuidString) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Close tab", "关闭标签页"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            // Active = milky raised chip (regularMaterial reads off-white in
            // light, a lighter shade in dark) with a hairline edge; inactive =
            // no fill, just the grey label, so it recedes into the strip.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isActive ? 0.10 : 0),
                                      lineWidth: 0.5)
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task { _ = await manager.switchTab(ref: id.uuidString) }
        }
        .accessibilityIdentifier("WickerBrowserTab\(index)")
    }

    /// Chip label: the page title if present, else the URL host, truncated to a
    /// compact ~16-char width so the strip stays tidy.
    private static func chipLabel(title: String, url: String) -> String {
        let base: String
        if !title.isEmpty {
            base = title
        } else if let host = URL(string: url)?.host, !host.isEmpty {
            base = host
        } else {
            base = L("New tab", "新标签页")
        }
        return base.count > 16 ? String(base.prefix(15)) + "…" : base
    }

    /// One compact toolbar row: status glyph, back / forward / reload, the address
    /// `TextField` (drives the SHARED `agentPage` on submit — the whole point: a
    /// page the user opens by hand becomes the page the agent then reads), and the
    /// pin toggle. The `WebView` fills the area below.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(manager.isAgentBrowsing
                                 ? AnyShapeStyle(Color.accentColor)
                                 : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .symbolEffect(.pulse, isActive: manager.isAgentBrowsing)
                .help(manager.isAgentBrowsing ? L("Wicker is browsing…", "Wicker 正在浏览…") : L("Agent browser", "智能体浏览器"))

            // History / reload, all driving the shared agentPage.
            navButton("chevron.left", help: L("Back", "后退")) { await manager.goBack() }
            navButton("chevron.right", help: L("Forward", "前进")) { await manager.goForward() }
            navButton("arrow.clockwise", help: L("Reload", "刷新")) { await manager.reload() }

            // Address bar — type a URL, press Enter (or the Go arrow) to load the
            // SHARED agentPage. Normalisation (scheme defaulting) is done on submit.
            TextField(L("Address", "地址"), text: $urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .onSubmit(submitAddress)
                .accessibilityIdentifier("WickerBrowserAddressField")

            navButton("arrow.right.circle.fill", help: L("Go", "前往"), action: { submitAddress() })

            // Pin keeps the panel open after the agent goes idle. Toggling
            // it off while idle slides the panel back out (the caller drops
            // it from the right region). While the agent is actively
            // browsing the panel stays regardless, so the control reads as a
            // pure pin rather than a hide button.
            Button {
                withAnimation(.snappy(duration: 0.25)) { pinnedOpen.toggle() }
            } label: {
                Image(systemName: pinnedOpen ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pinnedOpen
                                     ? AnyShapeStyle(Color.accentColor)
                                     : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
            .buttonStyle(.plain)
            .help(pinnedOpen ? L("Unpin browser panel", "取消固定浏览器面板") : L("Keep browser panel open", "保持浏览器面板打开"))
            .accessibilityIdentifier("WickerBrowserPanelToggle")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Seed the field from the live page on first appearance, then track every
        // navigation (user- OR agent-driven) so the bar always shows where the
        // shared agentPage actually is.
        .onAppear { urlText = manager.agentCurrentURL?.absoluteString ?? "" }
        .onChange(of: manager.agentCurrentURL) { _, newValue in
            urlText = newValue?.absoluteString ?? ""
        }
    }

    /// A small plain SF-Symbol toolbar button wrapping an async manager action.
    private func navButton(_ symbol: String,
                           help: String,
                           action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Normalise the typed address (default the scheme to https when omitted) and
    /// load the SHARED `agentPage`. A blank / unparseable entry is a no-op.
    private func submitAddress() {
        guard let url = BrowserSessionManager.normalizedURL(urlText) else { return }
        Task { await manager.userNavigate(url) }
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
            // SaaS tier: WickServer brokers chat via its OpenRouter key
            // through an OpenAI-compatible `/v1/chat/completions`
            // endpoint. Wicker just points the existing OAI-compat
            // client at <serverBaseURL>/v1 — no custom client needed.
            // Subscription auth (Bearer serverAuthToken) is plumbed
            // through; empty token = anon (fine for dev).
            guard let base = URL(string: settings.serverBaseURL) else {
                return nil
            }
            let url = base.appendingPathComponent("v1")
            let token: String? = settings.serverAuthToken.isEmpty
                ? nil
                : settings.serverAuthToken
            return OpenAICompatibleProvider(baseURL: url, apiKey: token)

        case .anthropic:
            guard !settings.currentAPIKey.isEmpty else { return nil }
            let baseURL = URL(string: settings.byoBaseURL)
                ?? URL(string: ProviderKind.anthropic.defaultBaseURL)!
            return AnthropicProvider(apiKey: settings.currentAPIKey,
                                      baseURL: baseURL)

        case .claudeCode:
            // Locally-installed `claude` CLI driven by the user's
            // subscription. Empty path → resolve from $PATH (the
            // Settings UI tells users this; we honour it here so
            // an empty `claudeCodeCLIPath` doesn't pass `""` to
            // `Process.executableURL` and instantly fail spawn).
            let cli = settings.claudeCodeCLIPath.isEmpty
                ? "claude"
                : settings.claudeCodeCLIPath
            return ClaudeCodeProvider(cliPath: cli, mode: .subscription)

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
