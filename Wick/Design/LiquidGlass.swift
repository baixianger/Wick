import SwiftUI

/// Thin wrapper over the iOS 26 / macOS 26 (Tahoe) Liquid Glass APIs.
/// The app's deployment floor is macOS 26 so no fallback paths are
/// needed — every entry point here calls the real glass API directly.
///
/// - `liquidGlass(...)` modifier — general surface backdrop.
/// - `LiquidGlassPillBar` — segmented selector with a single morphing
///   glass highlight that slides between pills (no fade-in / fade-out).
/// - `LiquidGlassButtonStyle` — `.glass` / `.glassProminent` mirror so
///   call sites stay one line.

// MARK: - Surface modifier

extension View {

    /// Apply a Liquid Glass surface to this view.
    ///
    /// Order matters: call after layout / padding modifiers.
    func liquidGlass(cornerRadius: CGFloat = 14,
                     tint: Color? = nil,
                     interactive: Bool = false) -> some View
    {
        modifier(LiquidGlassRealModifier(cornerRadius: cornerRadius,
                                          tint: tint,
                                          interactive: interactive))
    }
}

private struct LiquidGlassRealModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        switch (tint, interactive) {
        case (let t?, true):
            content.glassEffect(.regular.tint(t).interactive(),
                                in: .rect(cornerRadius: cornerRadius))
        case (let t?, false):
            content.glassEffect(.regular.tint(t),
                                in: .rect(cornerRadius: cornerRadius))
        case (nil, true):
            content.glassEffect(.regular.interactive(),
                                in: .rect(cornerRadius: cornerRadius))
        case (nil, false):
            content.glassEffect(.regular,
                                in: .rect(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - Pill bar (morphing highlight)

/// Toolbar-style row of mutually-exclusive pills. The selection highlight
/// is a SINGLE glass surface that morphs between pill positions via
/// `matchedGeometryEffect` + `glassEffectID` — never a fade. Wrapped in
/// a `GlassEffectContainer` so adjacent glass surfaces (the highlight,
/// plus any other glass siblings inside) interact as one.
struct LiquidGlassPillBar<Item: Hashable & Identifiable, Label: View>: View {
    let items: [Item]
    @Binding var selection: Item
    @ViewBuilder var label: (Item, Bool) -> Label

    @Namespace private var morphNS

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(items) { item in
                    pill(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func pill(for item: Item) -> some View {
        let isOn = item == selection
        Button {
            withAnimation(.snappy(duration: 0.28)) { selection = item }
        } label: {
            label(item, isOn)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Capsule())
                .background(highlight(visible: isOn))
        }
        .buttonStyle(.plain)
    }

    /// Only the SELECTED pill renders the highlight; SwiftUI animates it
    /// between positions because `matchedGeometryEffect` + `glassEffectID`
    /// share a namespace across pills.
    @ViewBuilder
    private func highlight(visible: Bool) -> some View {
        if visible {
            Capsule()
                .fill(Color.white.opacity(0.08))
                .matchedGeometryEffect(id: "pillHighlight", in: morphNS)
                .glassEffect(.regular.interactive(), in: Capsule())
                .glassEffectID("pillHighlight", in: morphNS)
        }
    }
}

// MARK: - Glass button style

/// Wrap a button in a Liquid Glass surface. `prominent: true` for the
/// primary action style (tinted with `.accentColor`); plain by default.
struct LiquidGlassButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var cornerRadius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.tint)
                        .glassEffect(.regular.tint(.accentColor).interactive(),
                                     in: .rect(cornerRadius: cornerRadius))
                } else {
                    Color.clear
                        .glassEffect(.regular.interactive(),
                                     in: .rect(cornerRadius: cornerRadius))
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
