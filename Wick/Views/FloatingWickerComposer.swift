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
    @FocusState private var inputFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $draft, axis: .vertical)
                // Sticky 2-line state: grows to 2 lines on focus AND
                // stays there as long as there's draft content
                // (`!draft.isEmpty`). Only an empty + unfocused
                // composer collapses back to 1 line — typing
                // anything keeps the taller surface.
                .lineLimit(twoLineMode ? 2...6 : 1...1)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: 320)
                .liquidGlass(cornerRadius: 14)
                .intelligenceGlow(
                    // Always-on + constant intensity. The floating
                    // composer reads as "Wicker is alive and
                    // listening" regardless of focus.
                    active: true,
                    cornerRadius: 14,
                    intensity: 0.85
                )
                .focused($inputFocused)
                .animation(.smooth(duration: 0.25), value: twoLineMode)
                .onSubmit { submit() }

            // Send button matches the 1-line text-field height (36pt)
            // and bottom-aligns with the field so on a 2-line
            // composer it sits in the lower right corner — visually
            // attached to the input rather than floating above its
            // bottom edge.
            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary)
                    .frame(width: 36, height: 36)
                    .liquidGlass(cornerRadius: 18)
                    .intelligenceGlow(
                        active: true,
                        cornerRadius: 18,
                        intensity: 0.85
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSubmit)
            .help("Ask Wicker (⌘⏎)")
            .accessibilityLabel("Ask Wicker")
            .accessibilityIdentifier("FloatingComposerSendButton")
        }
        .padding(10)
    }

    /// Whether to render the 2-line textarea. True when the user
    /// has focus OR there's any draft content sitting in the
    /// composer — so typing something then clicking elsewhere
    /// doesn't collapse the editor back to a 1-line bar mid-edit.
    private var twoLineMode: Bool {
        inputFocused || !draft.isEmpty
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
