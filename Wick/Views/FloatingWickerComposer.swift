import SwiftUI

/// Bottom-right floating "Ask Wicker" composer. Visible on every
/// non-Wicker route — Portfolio, Market, ticker detail. The single
/// entry point for asking the agent anything, replacing the
/// previously-duplicated in-ticker AI tab input.
///
/// Flow:
///   1. User types a question and submits
///   2. We create a new `ChatSession` (optionally pinned to the
///      current ticker), append the user message, and switch the
///      app's route to `.wicker`
///   3. `ConversationView.onAppear` detects the unanswered user
///      turn and auto-dispatches the LLM call — the floating
///      composer hands the conversation off to the Wicker
///      workspace seamlessly
///
/// Hidden on `.wicker` itself (the workspace has its own in-place
/// composer) and on Settings (which is a separate Scene).
struct FloatingWickerComposer: View {
    @Bindable var chat: ChatStore
    @Binding var route: SidebarRoute?
    /// Symbol from the current route — passed through to
    /// `ChatSession.pinnedSymbol` so the new session is anchored to
    /// whatever the user was looking at when they typed.
    let contextSymbol: String?

    @Environment(AgentSettings.self) private var settings
    @State private var draft: String = ""
    @State private var expanded: Bool = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: expanded ? 480 : 280)
                .liquidGlass(cornerRadius: 14)
                .intelligenceGlow(
                    active: inputFocused,
                    cornerRadius: 14,
                    intensity: 0.75
                )
                .focused($inputFocused)
                .onChange(of: inputFocused) { _, focused in
                    withAnimation(.snappy(duration: 0.22)) { expanded = focused }
                }
                .onSubmit { submit() }

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSubmit)
            .help("Ask Wicker (⌘⏎)")
        }
        .padding(10)
    }

    private var placeholder: String {
        if let sym = contextSymbol {
            return "Ask Wicker about \(sym)…"
        }
        return "Ask Wicker…"
    }

    private var canSubmit: Bool {
        settings.canRun
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Hand off to the Wicker workspace:
    ///   1. New session, optionally pinned to the current ticker
    ///   2. Append the user message immediately so the workspace
    ///      shows it on the very first render
    ///   3. Route switches → WickerView mounts → its auto-continue
    ///      detects the unanswered user turn and dispatches the LLM
    ///      call (see ConversationView.onAppear)
    private func submit() {
        guard canSubmit else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        inputFocused = false
        let sessionID = chat.newSession(pinnedSymbol: contextSymbol)
        chat.append(ChatMessage(role: .user, text: text), to: sessionID)
        route = .wicker
    }
}
