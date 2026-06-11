import SwiftUI

/// Apple-Intelligence-style edge glow — a smooth flowing multicolor
/// sheen that travels around a rounded-rectangle outline.
///
/// ## Why this was redesigned
///
/// The previous implementation was a faithful port of the React
/// `border-beam` library: **nine fixed-position saturated radial
/// ellipses** + a rotating conic sweep + a ring mask. It looked good on
/// dark, but **muddy / dirty on white**. The reason is colour theory,
/// not opacity: nine semi-transparent, heavily-saturated radials
/// (deep blue, deep green, magenta, violet…) composited over a
/// near-white background each pull the result *toward grey*. Adjacent
/// spikes overlap additively and the overlaps average to a dull
/// brownish haze — the classic "rainbow mud over white". Raising
/// opacity / saturation (the earlier patch) only deepens the mud.
///
/// Apple's actual Apple-Intelligence / Siri glow is the opposite of a
/// hard static rainbow: a small set of **luminous, high-value pastel
/// hues** arranged in **one smooth gradient** that *flows* along the
/// edge, elegant and translucent. So this rewrite drops to that
/// vocabulary.
///
/// ## Technique (AngularGradient, not a 9-spike canvas)
///
/// A single `AngularGradient` of six luminous pastels (the
/// community-standard Apple-Intelligence palette — purple `BC82F3`,
/// pink `F5B9EA`, blue `8D9FFF`, violet `AA6EEE`, red `FF6778`,
/// orange `FFBA71`) is rotated continuously around the rect and masked
/// to its outline. Because it's *one* gradient, neighbouring hues melt
/// into each other instead of compositing as overlapping saturated
/// blobs — no additive mud. It's stroked at two scales:
///
///   1. **Halo** — a fatter, heavily-blurred stroke that bleeds a soft
///      coloured bloom just outside the outline.
///   2. **Edge** — a hairline stroke, lightly blurred, that draws the
///      crisp luminous line on the outline itself.
///
/// The whole thing rotates (smooth travel) and breathes (a slow opacity
/// pulse) so it reads as "thinking", not as a static frame.
///
/// ## Light vs dark — a deliberate, documented choice
///
/// The muddiness on white is a *compositing* problem, so the fix is a
/// per-scheme **blend mode**, not just different numbers:
///
/// - **Light mode** composites the glow with `.plusLighter`. Over a
///   white surface this means the glow can only ever *add light* — it
///   can never darken a pixel toward grey, which is precisely what
///   produced the dirty look. Pastel hues at high value + plusLighter
///   give a clean, faintly iridescent sheen that sits *on* the white
///   rather than smudging it. Saturation is held slightly below 1 and
///   the colours are already high-value pastels, so nothing reads as a
///   harsh primary. Translucency is higher (lower base opacity) — the
///   effect should whisper on white, not shout.
/// - **Dark mode** composites normally (`.normal`) and runs the same
///   palette a touch more saturated and more opaque. Luminous pastels
///   over a dark surface already pop, so no blend trick is needed; the
///   halo simply blooms against the dark backing.
///
/// Reduce-Motion freezes both the rotation and the breathing pulse (the
/// glow holds a static, still-pretty frame), matching the previous
/// behaviour. No private Apple API is used — this is the documented,
/// shader-free SwiftUI approach (confirmed by [[apple-api-research-first]]).
///
/// Public API is unchanged: `intelligenceGlow(active:cornerRadius:intensity:)`.

extension View {

    /// Apply the Apple-Intelligence glow to this view.
    ///
    /// - Parameters:
    ///   - active: gate the effect (focused / pending / route-active).
    ///   - cornerRadius: corner radius of the underlying rounded
    ///     rectangle. For circular targets, pass `size / 2`.
    ///   - intensity: 0…1 loudness multiplier.
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

    /// The luminous Apple-Intelligence pastel palette. These are
    /// **high-value** colours (bright, lightly-saturated) — the single
    /// most important choice for reading cleanly on white. Deep,
    /// fully-saturated hues (the old palette) darken toward grey when
    /// composited translucently over a light surface; high-value
    /// pastels stay bright. The list wraps (last == first) so the
    /// `AngularGradient` is seamless across 0°/360°.
    private static let palette: [Color] = [
        rgb(188, 130, 243),   // BC82F3 purple
        rgb(245, 185, 234),   // F5B9EA pink
        rgb(141, 159, 255),   // 8D9FFF blue
        rgb(170, 110, 238),   // AA6EEE violet
        rgb(255, 103, 120),   // FF6778 red
        rgb(255, 186, 113),   // FFBA71 orange
        rgb(198, 134, 255),   // C686FF violet
        rgb(188, 130, 243),   // wrap back to BC82F3 → seamless ring
    ]

    /// Rotation period for the travelling sheen (full turn). Slow and
    /// elegant — Apple's glow drifts rather than races.
    private static let rotationPeriod: Double = 8.0

    /// Breathing (opacity pulse) period and depth. A gentle ±swell so
    /// the glow reads as alive / "thinking".
    private static let breathPeriod: Double = 3.2
    private static let breathDepth: Double = 0.18

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let now = ctx.date.timeIntervalSinceReferenceDate

            // Continuous rotation of the gradient = the sheen travelling
            // around the edge. Frozen under Reduce Motion.
            let angle: Double = reduceMotion
                ? 0.0
                : (now.truncatingRemainder(dividingBy: Self.rotationPeriod)
                    / Self.rotationPeriod) * 360.0

            // Slow breathing pulse around 1.0 (1 − depth … 1). Frozen
            // (held at full) under Reduce Motion.
            let breath: Double = reduceMotion
                ? 1.0
                : 1.0 - Self.breathDepth
                    * (0.5 - 0.5 * cos(now / Self.breathPeriod * 2.0 * .pi))

            render(angle: angle, breath: breath)
        }
    }

    @ViewBuilder
    private func render(angle: Double, breath: Double) -> some View {
        let theme = (scheme == .dark) ? Self.darkTheme : Self.lightTheme
        let shape = RoundedRectangle(cornerRadius: cornerRadius,
                                      style: .continuous)
        let gradient = AngularGradient(
            gradient: Gradient(colors: Self.palette),
            center: .center,
            angle: .degrees(angle))

        let alpha = theme.baseOpacity * intensity * breath

        // Two stroked layers sharing the *same* single gradient:
        //   • Halo — fat + blurred → soft coloured bloom outside edge.
        //   • Edge — hairline + light blur → crisp luminous line.
        // One gradient (not 9 overlapping radials) is what keeps the
        // colour transitions smooth and mud-free.
        ZStack {
            shape
                .stroke(gradient, lineWidth: theme.haloWidth)
                .blur(radius: theme.haloBlur)
                .opacity(theme.haloOpacity)

            shape
                .stroke(gradient, lineWidth: theme.edgeWidth)
                .blur(radius: theme.edgeBlur)
        }
        .saturation(theme.saturation)
        .opacity(alpha)
        // Light: plusLighter so the glow can only ADD light over white,
        // never darken it toward grey (the source of the old muddiness).
        // Dark: normal — luminous pastels already bloom on a dark backing.
        .blendMode(theme.blendMode)
        .compositingGroup()   // contain the blend mode to this overlay
    }

    // MARK: - Themes

    private struct Theme {
        /// Fat blurred bloom stroke (outside the outline).
        let haloWidth: CGFloat
        let haloBlur: CGFloat
        /// Halo carries less weight than the crisp edge so the bloom
        /// stays soft and translucent rather than a thick coloured band.
        let haloOpacity: Double
        /// Hairline edge stroke (the crisp luminous line) + its light blur.
        let edgeWidth: CGFloat
        let edgeBlur: CGFloat
        /// Global alpha for the whole effect (before intensity / breath).
        let baseOpacity: Double
        /// Saturation trim. Kept ≤ 1 on light so pastels don't read as
        /// harsh primaries against white.
        let saturation: Double
        /// Per-scheme compositing — the real fix for white-mode muddiness.
        let blendMode: BlendMode
    }

    /// Dark: vivid and a touch more opaque; normal compositing lets the
    /// halo bloom against the dark backing.
    private static let darkTheme = Theme(
        haloWidth: 3.5,
        haloBlur: 11,
        haloOpacity: 0.7,
        edgeWidth: 1.2,
        edgeBlur: 1.5,
        baseOpacity: 0.9,
        saturation: 1.05,
        blendMode: .normal)

    /// Light: lower base opacity (whisper, don't shout) + `plusLighter`
    /// so the glow only ever brightens the white surface — this is what
    /// makes it read clean instead of dirty. Saturation held just below
    /// 1 to keep the high-value pastels airy.
    private static let lightTheme = Theme(
        haloWidth: 3.0,
        haloBlur: 9,
        haloOpacity: 0.6,
        edgeWidth: 1.0,
        edgeBlur: 1.0,
        baseOpacity: 0.7,
        saturation: 0.95,
        blendMode: .plusLighter)
}

// MARK: - Helpers

private func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
    Color(red: Double(r) / 255.0,
          green: Double(g) / 255.0,
          blue: Double(b) / 255.0)
}
