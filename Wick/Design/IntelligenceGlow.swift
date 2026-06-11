import SwiftUI

/// Apple-Intelligence-style edge glow — a **continuous, full-perimeter
/// inner-glowing light strip** (内发光的灯带) wrapped around the rounded
/// rectangle, whose **colour flows / cycles seamlessly around the whole
/// closed loop** (头尾相接，颜色流动循环) while the strip **breathes** (a slow
/// brightness swell). Think of an LED strip embedded just inside the panel's
/// edge: the *entire* border is lit at all times — what MOVES is the colour,
/// drifting round and round the ring — and the soft halo bleeds *inward*,
/// lighting the interior, rather than blooming outward.
///
/// ## What this is (and what it deliberately is NOT)
///
/// This is **not** a discrete bright comet with a dark tail and a gap. The
/// whole perimeter glows continuously; the only motion is hue flowing around
/// the loop. Three properties, three mechanisms:
///
/// 1. **灯带 / continuous flowing strip** — the lit element is the **full**
///    `RoundedRectangle` outline (no `.trim` window, no gap), stroked and
///    then *masked* by a centred **`AngularGradient`** built from the
///    Apple-Intelligence pastels. The palette **wraps seamlessly** — the
///    last stop's colour equals the first's — so there is no visible seam at
///    the `0°/360°` boundary. Continuously **rotating** that angular gradient
///    makes the colours cycle around the entire edge: the colour flows, the
///    strip never goes dark. A gentle `sin` modulation on the rotation gives
///    an organic, non-mechanical drift without ever reversing.
///
/// 2. **内发光 / inner glow** — under the crisp stroke sit one or more fat,
///    heavily-blurred copies of the same full-perimeter stroke. The entire
///    stack is `.compositingGroup()`-ed and **masked to the filled shape**
///    (`.mask(shape.fill())`), so every blurred halo is clipped to the panel
///    interior — the soft light can only spill *inward*, never bloom outward
///    past the edge. Each layer is inset by half its line width so the stroke
///    lands *inside* the edge (the `strokeBorder` effect).
///
/// 3. **呼吸 / breathing** — the whole stack's opacity is multiplied by a slow
///    cosine swell `0.7 + 0.3·(0.5 − 0.5·cos(2π t / breathPeriod))`
///    (`breathPeriod ≈ 3.4 s`), independent of the colour flow, so the strip
///    swells and dims *while* the hue cycles.
///
/// ## Light vs dark
///
/// - **Dark mode**: `.normal` blend — the inner halo blooms naturally
///   against the dark panel; the pastels run a touch more saturated/opaque.
/// - **Light mode**: the whole stack is composited with `.plusLighter` inside
///   a `compositingGroup`, so over the near-white panel the strip can only
///   ever *add* light and never muddies toward grey; base opacity is held a
///   touch lower for an airy inner sheen, with high-value pastels.
///
/// ## Reduce Motion
///
/// The single `TimelineView(.animation(paused:))` is paused under
/// `accessibilityReduceMotion`; we then park the gradient at a fixed rotation
/// with the breathing held at its mid value — a still, still-pretty frame. No
/// private Apple API is used; this is the documented, shader-free SwiftUI
/// approach (confirmed by [[apple-api-research-first]]).
///
/// Public API is unchanged: `intelligenceGlow(active:cornerRadius:intensity:)`.

extension View {

    /// Apply the Apple-Intelligence glow to this view.
    ///
    /// - Parameters:
    ///   - active: gate the effect (focused / pending / route-active).
    ///   - cornerRadius: corner radius of the underlying rounded
    ///     rectangle. For circular targets, pass `size / 2`.
    ///   - intensity: 0…1 loudness multiplier — scales the strip's
    ///     brightness and halo.
    func intelligenceGlow(active: Bool,
                          cornerRadius: CGFloat = 14,
                          intensity: Double = 1.0) -> some View
    {
        modifier(IntelligenceGlowModifier(active: active,
                                           cornerRadius: cornerRadius,
                                           intensity: intensity))
    }
}

// MARK: - Modifier

private struct IntelligenceGlowModifier: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat
    let intensity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    IntelligenceGlow(cornerRadius: cornerRadius,
                                      intensity: intensity,
                                      reduceMotion: reduceMotion)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: active)
    }
}

// MARK: - The glow itself

private struct IntelligenceGlow: View {
    let cornerRadius: CGFloat
    let intensity: Double
    let reduceMotion: Bool

    @Environment(\.colorScheme) private var scheme

    // MARK: Tunables

    /// Seconds for one full revolution of the colour around the loop.
    private static let flowPeriod: Double = 6.5

    /// Breathing period (seconds) — the slow brightness swell.
    private static let breathPeriod: Double = 3.4

    /// Non-uniform-speed amplitude (in turns). The rotation is
    /// `φ + flowWarp·sin(2π φ)`; this stays monotonic for
    /// `flowWarp < 1/2π ≈ 0.159`, so 0.10 gives a gentle speed-up / ease-off
    /// without ever reversing the flow.
    private static let flowWarp: Double = 0.10

    /// Where the parked gradient sits (turns) under Reduce Motion.
    private static let parkedTurn: Double = 0.0

    /// The full-perimeter stroke layers, halo → core. Each is the **whole**
    /// rounded-rect outline (no trim) masked by the flowing angular gradient:
    ///   - `width`   — stroke line width.
    ///   - `blur`    — blur radius (the halo is fat and soft).
    ///   - `opacity` — relative brightness (core brightest, halo softest).
    private static let layers: [(width: CGFloat,
                                 blur: CGFloat,
                                 opacity: Double)] = [
        (16, 20, 0.45),   // fat inner halo — soft, masked inward
        ( 8,  7, 0.55),   // mid bloom
        ( 3,  1, 1.00),   // crisp bright core strip
    ]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let s = state(at: ctx.date.timeIntervalSinceReferenceDate)
            render(turn: s.turn, breath: s.breath)
        }
    }

    /// Resolve the gradient's rotation (in turns, non-uniform speed, looping)
    /// and the breathing multiplier for the given timeline instant. Frozen to
    /// a parked frame under Reduce Motion.
    private func state(at now: Double) -> (turn: Double, breath: Double) {
        guard !reduceMotion else {
            return (Self.parkedTurn, 0.85)   // calm mid-breath, parked
        }
        let phi = (now / Self.flowPeriod).truncatingRemainder(dividingBy: 1)
        let turn = phi + Self.flowWarp * sin(2 * .pi * phi)
        let b = 0.5 - 0.5 * cos(2 * .pi * now / Self.breathPeriod)
        return (turn, 0.7 + 0.3 * b)
    }

    @ViewBuilder
    private func render(turn: Double, breath: Double) -> some View {
        let theme = (scheme == .dark) ? Self.darkTheme : Self.lightTheme
        let shape = RoundedRectangle(cornerRadius: cornerRadius,
                                      style: .continuous)
        // The flowing colour: a centred angular gradient whose palette wraps
        // seamlessly (last stop == first stop), rotated by `turn` so the hues
        // cycle around the loop with no seam at the 0°/360° boundary.
        let flow = AngularGradient(
            gradient: Gradient(colors: theme.palette),
            center: .center,
            angle: .degrees(turn * 360))

        ZStack {
            ForEach(Self.layers.indices, id: \.self) { i in
                let layer = Self.layers[i]
                // The FULL rounded-rect outline (no trim → no gap), inset by
                // half its width so the stroke lands inside the edge, then
                // masked by the flowing gradient so the whole perimeter shows
                // the cycling colour at once.
                shape
                    .inset(by: layer.width / 2)
                    // Fill the stroke WITH the flowing gradient (not mask it).
                    // `.stroke(style:).mask(flow)` was the bug: a plain stroke
                    // defaults to the black foreground, and an opaque gradient
                    // used as an alpha mask leaves it black — a dark ring with
                    // no colour. `.stroke(content:style:)` paints the stroke in
                    // the gradient itself, so the hues actually show + flow.
                    .stroke(flow, style: StrokeStyle(lineWidth: layer.width * intensity,
                                                     lineCap: .round))
                    .blur(radius: layer.blur * intensity)
                    .opacity(layer.opacity)
            }
        }
        // Mask the entire stack to the filled shape so every blurred halo is
        // clipped to the panel interior — the soft light can only spill
        // *inward* (内发光), never bloom outward past the edge.
        .compositingGroup()
        .mask(shape.fill())
        .opacity(theme.baseOpacity * intensity * breath)   // breathing swell
        // Light: plusLighter so the strip only ever ADDS light over white,
        // never darkening toward grey. Dark: normal — the halo blooms.
        .blendMode(theme.blendMode)
        .compositingGroup()   // contain the blend mode to this overlay
    }

    // MARK: - Themes

    private struct Theme {
        /// Global alpha for the whole strip (before intensity & breathing).
        let baseOpacity: Double
        /// The flowing palette. **The last colour equals the first** so the
        /// angular gradient wraps with no visible seam at 0°/360°.
        let palette: [Color]
        /// Per-scheme compositing.
        let blendMode: BlendMode
    }

    /// Dark: more saturated/opaque pastels, normal blend — the inner halo
    /// blooms naturally against the dark panel.
    private static let darkTheme = Theme(
        baseOpacity: 0.95,
        palette: [
            rgb(0xB9, 0x8C, 0xFF),   // violet
            rgb(0xFF, 0x8F, 0xC8),   // pink
            rgb(0xFF, 0xB4, 0x8C),   // warm peach
            rgb(0x8C, 0xD4, 0xFF),   // sky blue
            rgb(0x9E, 0x8C, 0xFF),   // indigo
            rgb(0xB9, 0x8C, 0xFF),   // → back to violet (seamless wrap)
        ],
        blendMode: .normal)

    /// Light: lower base opacity (an airy inner sheen) + `plusLighter` so the
    /// strip only brightens the white surface, staying clean. High-value
    /// pastels read on white without muddying.
    private static let lightTheme = Theme(
        baseOpacity: 0.85,
        palette: [
            rgb(0xC8, 0xA8, 0xFF),   // violet
            rgb(0xFF, 0xAE, 0xD8),   // pink
            rgb(0xFF, 0xC8, 0xA8),   // peach
            rgb(0xA8, 0xDC, 0xFF),   // sky blue
            rgb(0xB4, 0xA8, 0xFF),   // indigo
            rgb(0xC8, 0xA8, 0xFF),   // → back to violet (seamless wrap)
        ],
        blendMode: .plusLighter)
}

// MARK: - Helpers

private func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
    Color(red: Double(r) / 255.0,
          green: Double(g) / 255.0,
          blue: Double(b) / 255.0)
}
