import SwiftUI

/// Apple-Intelligence-style edge glow — a faithful port of
/// **jacobamobin/AppleIntelligenceGlowEffect** (`IOS.swift`, the
/// `GlowEffect` view), adapted to glow the rounded-rectangle *outline*
/// of a host view (the composer) and driven by `cornerRadius` +
/// `intensity`.
///
/// ## jacobamobin's exact technique (the thing we're matching)
///
/// The upstream `GlowEffect` is **not** a rotating conic sweep and not a
/// canvas of fixed radial blobs. Its signature move is far simpler and
/// is what gives it the lava-lamp "Apple Intelligence" shimmer:
///
///   - One `AngularGradient` built from **six luminous pastel stops**
///     (`BC82F3` purple, `F5B9EA` pink, `8D9FFF` blue, `FF6778` red,
///     `FFBA71` orange, `C686FF` violet) — the canonical palette.
///   - Each stop's *location* is a **random** value in `0...1`, and the
///     stops are sorted ascending. Every `0.5 s` the locations are
///     re-randomised and animated to their new positions over a `1.0 s`
///     `easeInOut`. Because only the **stop offsets** move (not an
///     angle), the colour bands stretch, squeeze and slide into each
///     other — the hues *flow* rather than rigidly spin.
///   - The gradient is stroked onto a `RoundedRectangle` via
///     `strokeBorder` in **four stacked layers** of increasing weight
///     and blur, all sharing the same animated stops:
///
///         EffectNoBlur  width 6   blur 0    (crisp luminous line)
///         Effect        width 9   blur 4
///         Effect        width 11  blur 12
///         Effect        width 15  blur 15   (fat soft outer bloom)
///
///     The four layers are wrapped in a `.drawingGroup()` (each inner
///     `Effect` additionally `.compositingGroup()`-ed) so the stack
///     rasterises and blends as one.
///
/// Note the upstream uses **no** rotation / scale / offset transform at
/// all; "motion" is entirely the animated re-randomisation of the six
/// gradient-stop locations. This port reproduces that faithfully.
///
/// ## How we adapted it to our use
///
/// Upstream hard-codes a full-screen bezel (`cornerRadius: 55`, screen
/// bounds, magic `.padding(.top, -17/-26)` to hug the device corners).
/// We instead size every layer to the host view via `strokeBorder` on a
/// `RoundedRectangle(cornerRadius:)` from the call site, so the glow
/// traces the composer's actual outline at any corner radius. The four
/// upstream widths/blurs are scaled by `intensity` (and the whole stack
/// faded by it) so the same call can whisper or shout. The `Timer`
/// publisher + `@State` stops are replaced by a `TimelineView`-driven
/// phase so the re-randomisation is deterministic and pauses cleanly
/// under Reduce Motion — but the *behaviour* (new random stop offsets
/// eased in on a ~0.5 s cadence) is identical.
///
/// ## Light vs dark — a deliberate, documented choice
///
/// jacobamobin's effect is designed against **dark** wallpapers. Ported
/// verbatim onto our near-white composer surface it goes muddy: six
/// translucent saturated bands stroked over white each pull the result
/// toward grey, and the overlapping blurred layers average to a dull
/// haze. The fix is a *compositing* fix, not new numbers:
///
/// - **Dark mode** is the faithful port: `.normal` blend, full palette,
///   the upstream widths/blurs. Luminous pastels bloom against the dark
///   backing exactly as upstream intends.
/// - **Light mode** composites the whole (drawing-grouped) stack with
///   `.plusLighter` inside a `compositingGroup`. Over white, plusLighter
///   means the glow can only ever *add* light — it can never darken a
///   pixel toward grey, which is precisely what produced the dirty look.
///   Base opacity is held lower (whisper, don't shout) and saturation a
///   hair below 1 so the high-value pastels stay airy on white.
///
/// Reduce-Motion freezes the stop re-randomisation to a single static
/// frame (still pretty), matching the file's prior behaviour. No private
/// Apple API is used — this is the documented, shader-free SwiftUI
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

    /// The canonical Apple-Intelligence palette, in upstream order. These
    /// six hues are stroked as one `AngularGradient`; only their *stop
    /// locations* animate (see below). High-value pastels — the single
    /// most important choice for reading cleanly on white.
    private static let palette: [Color] = [
        rgb(0xBC, 0x82, 0xF3),   // BC82F3 purple
        rgb(0xF5, 0xB9, 0xEA),   // F5B9EA pink
        rgb(0x8D, 0x9F, 0xFF),   // 8D9FFF blue
        rgb(0xFF, 0x67, 0x78),   // FF6778 red
        rgb(0xFF, 0xBA, 0x71),   // FFBA71 orange
        rgb(0xC6, 0x86, 0xFF),   // C686FF violet
    ]

    /// Cadence (seconds) at which upstream re-randomises the gradient
    /// stop locations (`Timer.publish(every: 0.5…)`), and the easing
    /// duration each new set of offsets is animated over
    /// (`.easeInOut(duration: 1.0)`).
    private static let stepPeriod: Double = 0.5
    private static let easeDuration: Double = 1.0

    /// The four upstream stroke layers: `(lineWidth, blurRadius)`, from
    /// the crisp `EffectNoBlur` (blur 0) out to the fat soft bloom.
    private static let layers: [(width: CGFloat, blur: CGFloat)] = [
        (6, 0),     // EffectNoBlur
        (9, 4),     // Effect
        (11, 12),   // Effect
        (15, 15),   // Effect
    ]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let now = ctx.date.timeIntervalSinceReferenceDate

            // Reproduce upstream's "re-randomise stops every 0.5 s, ease
            // to the new offsets over 1.0 s" by interpolating between the
            // random stop-set of the current step and the next one. Each
            // step's offsets are seeded deterministically so the
            // TimelineView render is stable and Reduce-Motion can freeze
            // it. Frozen at step 0 under Reduce Motion.
            let step = reduceMotion
                ? 0.0
                : (now / Self.stepPeriod).rounded(.down)
            let frac = reduceMotion
                ? 0.0
                : min(1.0, (now - step * Self.stepPeriod) / Self.easeDuration)
            // easeInOut on the interpolation fraction.
            let t = frac * frac * (3.0 - 2.0 * frac)

            let from = Self.stops(seed: UInt64(bitPattern: Int64(step)))
            let to = Self.stops(seed: UInt64(bitPattern: Int64(step)) &+ 1)
            let offsets = zip(from, to).map { $0 + ($1 - $0) * t }

            render(offsets: offsets)
        }
    }

    @ViewBuilder
    private func render(offsets: [Double]) -> some View {
        let theme = (scheme == .dark) ? Self.darkTheme : Self.lightTheme
        let shape = RoundedRectangle(cornerRadius: cornerRadius,
                                      style: .continuous)
        let stops = zip(Self.palette, offsets).map { color, loc in
            Gradient.Stop(color: color, location: loc)
        }
        let gradient = AngularGradient(
            gradient: Gradient(stops: stops),
            center: .center)

        // Four stacked strokeBorder layers (upstream's ZStack), widths
        // and blurs scaled by intensity so the same call can whisper or
        // shout. `.drawingGroup()` rasterises the stack as one, matching
        // upstream and keeping the per-layer blends contained.
        ZStack {
            ForEach(Self.layers.indices, id: \.self) { i in
                let layer = Self.layers[i]
                shape
                    .strokeBorder(gradient,
                                  lineWidth: layer.width * intensity)
                    .blur(radius: layer.blur * intensity)
                    .compositingGroup()
            }
        }
        .drawingGroup()
        .saturation(theme.saturation)
        .opacity(theme.baseOpacity * intensity)
        // Light: plusLighter so the glow can only ADD light over white,
        // never darken it toward grey (the source of the muddiness when
        // upstream's dark-designed effect is dropped on white).
        // Dark: normal — luminous pastels already bloom on a dark backing.
        .blendMode(theme.blendMode)
        .compositingGroup()   // contain the blend mode to this overlay
    }

    /// Build the six random stop *locations* for a step, sorted ascending
    /// — upstream's `generateGradientStops()`, made deterministic per
    /// step (seeded) so the `TimelineView` render is stable and can be
    /// frozen under Reduce Motion.
    private static func stops(seed: UInt64) -> [Double] {
        var rng = SplitMix64(seed: seed)
        return (0..<palette.count)
            .map { _ in rng.nextUnitDouble() }
            .sorted()
    }

    // MARK: - Themes

    private struct Theme {
        /// Global alpha for the whole effect (before intensity).
        let baseOpacity: Double
        /// Saturation trim. Kept ≤ 1 on light so the pastels don't read
        /// as harsh primaries against white.
        let saturation: Double
        /// Per-scheme compositing — the real fix for white-mode muddiness.
        let blendMode: BlendMode
    }

    /// Dark: the faithful port — full palette, normal compositing lets
    /// the four blurred layers bloom against the dark backing.
    private static let darkTheme = Theme(
        baseOpacity: 0.95,
        saturation: 1.05,
        blendMode: .normal)

    /// Light: lower base opacity (whisper, don't shout) + `plusLighter`
    /// so the glow only ever brightens the white surface — this is what
    /// keeps it clean instead of dirty. Saturation held just below 1 to
    /// keep the high-value pastels airy.
    private static let lightTheme = Theme(
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

/// Tiny deterministic PRNG (SplitMix64) so each animation step's random
/// gradient-stop locations are reproducible — upstream uses
/// `Double.random(in: 0...1)` with `@State`; we seed per step instead so
/// the `TimelineView` render is stable and Reduce-Motion can hold a
/// single frame.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform `Double` in `0...1`.
    mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}
