import SwiftUI

/// Horizontal stepper that visualises the four-phase desk workflow
/// (Analysts → Research → Decision → Risk gate). Two duties:
///
/// 1. **Live progress** — during a desk run, the active phase glows
///    and earlier phases fill in solid. Replaces what used to be the
///    textual `runStatusStrip` row above the report.
/// 2. **Static provenance** — on a completed report, every node is
///    solid; the Risk node shows a warning chip when the risk manager
///    overrode the trader's call.
///
/// The view is purely presentational. The caller (`AITab`) maps the
/// runner phase / report shape to per-node `Status` values.
struct WorkflowStepper: View {

    enum Status: Equatable {
        /// Not yet reached. Dimmed node, hollow circle.
        case pending
        /// Currently active. Pulses; phase tint at full strength.
        case running
        /// Phase finished successfully. Solid fill + tint, checkmark
        /// overlay.
        case complete
        /// Phase finished but with a caveat — surfaces the risk
        /// override case at the gatekeep node. Amber tint + warning
        /// glyph regardless of base phase colour.
        case warning(label: String)
        /// Phase errored out. Red ring + cross glyph.
        case failed
    }

    let phases: [AgentPhase]
    /// Resolve a phase to its status. Pure function so callers can
    /// recompute on every render without caching.
    let statusFor: (AgentPhase) -> Status
    /// Optional handler for tapping a phase — typically used to scroll
    /// the report body to the corresponding section.
    var onTap: ((AgentPhase) -> Void)? = nil
    /// Compact mode: drops phase labels and shrinks the discs so the
    /// stepper can sit inside a header row next to a title + action
    /// button instead of occupying a row of its own.
    var compact: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var discSize: CGFloat { compact ? 18 : 26 }
    private var nodeFrameSize: CGFloat { compact ? 22 : 30 }
    private var glyphSize: CGFloat { compact ? 9 : 11 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(phases.enumerated()), id: \.element) { idx, phase in
                node(for: phase)
                if idx < phases.count - 1 {
                    connector(after: phase)
                }
            }
        }
        .padding(.horizontal, compact ? 2 : 4)
        .padding(.vertical, compact ? 0 : 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Desk workflow")
    }

    // MARK: - Node

    @ViewBuilder
    private func node(for phase: AgentPhase) -> some View {
        let status = statusFor(phase)
        Button {
            onTap?(phase)
        } label: {
            if compact {
                glyph(for: phase, status: status)
            } else {
                VStack(spacing: 4) {
                    glyph(for: phase, status: status)
                    Text(phase.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(labelTint(for: status, phase: phase))
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .help("\(phase.title) — \(spokenStatus(status))")
        .accessibilityLabel(
            "\(phase.title) phase, \(spokenStatus(status))"
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("WorkflowStep-\(phase.rawValue)")
    }

    @ViewBuilder
    private func glyph(for phase: AgentPhase, status: Status) -> some View {
        ZStack {
            // Base disc — solid when complete/running, hollow when pending.
            Circle()
                .fill(fillStyle(for: status, phase: phase))
                .frame(width: discSize, height: discSize)
                .overlay(
                    Circle()
                        .strokeBorder(strokeStyle(for: status, phase: phase),
                                       lineWidth: compact ? 1.0 : 1.4)
                )

            // Phase or status glyph.
            Image(systemName: overlayGlyph(for: phase, status: status))
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(glyphTint(for: status, phase: phase))

            // Outer pulse — only while running and only if reduce-motion
            // is off, so anxious users don't get a strobing dashboard.
            if case .running = status, !reduceMotion {
                Circle()
                    .strokeBorder(phase.color.opacity(0.5),
                                   lineWidth: compact ? 1.2 : 1.6)
                    .frame(width: discSize, height: discSize)
                    .scaleEffect(1.4)
                    .opacity(0)
                    .modifier(PulseModifier(tint: phase.color))
            }
        }
        .frame(width: nodeFrameSize, height: nodeFrameSize)
    }

    // MARK: - Connector

    @ViewBuilder
    private func connector(after phase: AgentPhase) -> some View {
        let nextPhase = nextPhaseAfter(phase)
        let active = isConnectorActive(from: phase, to: nextPhase)
        Rectangle()
            .fill(active
                  ? phase.color.opacity(0.55)
                  : Color.secondary.opacity(0.22))
            .frame(height: compact ? 1.5 : 2)
            .frame(maxWidth: compact ? 22 : .infinity)
            // In full mode we right-align with the disc, not the label
            // baseline; in compact mode there's no label, so no extra
            // bottom padding is needed.
            .padding(.horizontal, 2)
            .padding(.bottom, compact ? 0 : 14)
            .accessibilityHidden(true)
    }

    private func nextPhaseAfter(_ phase: AgentPhase) -> AgentPhase? {
        guard let i = phases.firstIndex(of: phase), i + 1 < phases.count
        else { return nil }
        return phases[i + 1]
    }

    /// A connector reads as "active" when the phase to its left is
    /// done — i.e. the workflow has progressed past that edge.
    private func isConnectorActive(from a: AgentPhase, to b: AgentPhase?) -> Bool {
        switch statusFor(a) {
        case .complete, .warning: return true
        default: return false
        }
    }

    // MARK: - Style helpers

    private func fillStyle(for status: Status, phase: AgentPhase) -> Color {
        switch status {
        case .pending:                  return Color.secondary.opacity(0.10)
        case .running:                  return phase.color.opacity(0.25)
        case .complete:                 return phase.color.opacity(0.85)
        case .warning:                  return Color.orange.opacity(0.85)
        case .failed:                   return Color.red.opacity(0.18)
        }
    }

    private func strokeStyle(for status: Status, phase: AgentPhase) -> Color {
        switch status {
        case .pending:                  return Color.secondary.opacity(0.32)
        case .running:                  return phase.color
        case .complete:                 return phase.color
        case .warning:                  return Color.orange
        case .failed:                   return Color.red
        }
    }

    private func glyphTint(for status: Status, phase: AgentPhase) -> Color {
        switch status {
        case .pending:                  return Color.secondary
        case .running:                  return phase.color
        case .complete, .warning:       return .white
        case .failed:                   return Color.red
        }
    }

    private func labelTint(for status: Status, phase: AgentPhase) -> Color {
        switch status {
        case .pending:                  return Color.secondary
        case .running:                  return phase.color
        case .complete:                 return .primary
        case .warning:                  return Color.orange
        case .failed:                   return Color.red
        }
    }

    /// What appears INSIDE the disc. Phase symbol on running/pending;
    /// a check on complete; a warning glyph on warning; an x on failed.
    private func overlayGlyph(for phase: AgentPhase, status: Status) -> String {
        switch status {
        case .pending, .running:  return phase.symbol
        case .complete:           return "checkmark"
        case .warning:            return "exclamationmark.triangle.fill"
        case .failed:             return "xmark"
        }
    }

    /// VoiceOver-friendly status word.
    private func spokenStatus(_ status: Status) -> String {
        switch status {
        case .pending:               return L("pending", "待执行")
        case .running:               return L("in progress", "进行中")
        case .complete:              return L("complete", "已完成")
        case .warning(let label):    return L("complete with caveat, \(label)", "完成但有提示，\(label)")
        case .failed:                return L("failed", "失败")
        }
    }
}

// MARK: - Pulse animation modifier

/// Wraps a view in a continuous pulse — scale 1 → 1.5 + fade — used
/// by the running phase node. Gated by `reduceMotion` at the call
/// site, so this modifier never needs to inspect the environment.
private struct PulseModifier: ViewModifier {
    let tint: Color
    @State private var pulse: Bool = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pulse ? 1.5 : 1.0)
            .opacity(pulse ? 0 : 0.7)
            .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false),
                       value: pulse)
            .onAppear { pulse = true }
    }
}
