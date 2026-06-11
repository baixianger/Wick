import SwiftUI

/// Apple-Intelligence-style edge glow — an **inner-glowing light strip**
/// (内发光的灯带) whose lit segment *travels* around the rounded-rectangle
/// perimeter, looping, while it **breathes** (a slow brightness swell) and
/// moves at **non-uniform speed**. Think of an LED strip embedded just
/// inside the panel's edge: a single bright comet of light chases along the
/// border path — through the corners — and its soft halo bleeds *inward*,
/// lighting the interior, rather than blooming outward.
///
/// ## What this is (and what it deliberately is NOT)
///
/// This is **not** a rotating multicolour gradient ring. Two earlier ports
/// animated an entire `AngularGradient` so the whole rainbow band spun /
/// morphed in place — wrong. The signature here is a *discrete* lit arc
/// **segment** (a marquee / LED-strip chase / comet) that runs along the
/// actual edge and loops seamlessly. Four properties, four mechanisms:
///
/// 1. **灯带 / traveling segment** — the lit arc is a moving window
///    `[p, p + segLen]` (with `segLen ≈ 0.2` of the perimeter) drawn via
///    **`.trim(from:to:)`** on the rounded-rect's stroke. `.trim` follows
///    the real path, corners included, so the light visibly rounds the
///    corners. When the window runs off the end (`p + segLen > 1`) it is
///    split into two pieces — `[p, 1]` and `[0, p + segLen − 1]` — so the
///    strip wraps across the seam with no gap.
///
/// 2. **内发光 / inner glow** — every layer is stroked with
///    `strokeBorder` (which paints *inside* the edge) and the entire glow
///    stack is **masked to the filled shape** (`.mask(shape.fill())`). A
///    fat, heavily-blurred trim sits underneath; because the mask clips it
///    to the panel interior, that halo can only spill *inward* — the soft
///    light reads as spilling into the panel from the inner edge, never as
///    an outward bloom.
///
/// 3. **呼吸 / breathing** — the segment's opacity is multiplied by a slow
///    cosine swell `0.7 + 0.3·(0.5 − 0.5·cos(2π t / breathPeriod))`
///    (`breathPeriod ≈ 3.4 s`). It is independent of travel, so the strip
///    swells and dims *while* it moves.
///
/// 4. **非匀速 / non-uniform speed** — the head position is
///    `p(t) = (φ + A·sin(2π φ)) mod 1`, `φ = (t / period) mod 1`,
///    `A ≈ 0.12`. The `sin` term keeps `p` monotonic (so the loop never
///    reverses) but makes the comet perceptibly speed up and ease off
///    around the lap — an organic, non-mechanical drift.
///
/// ## Comet body
///
/// The head is the brightest, crispest trim. Behind it, two shorter
/// trailing trims of decreasing opacity form a fading tail, and a fat
/// blurred trim under everything is the inner halo. All four share the same
/// traveling window (the tail pieces simply start a little *behind* the
/// head), so the whole thing reads as one luminous strip with a glowing
/// wake. The core is a bright near-white tinted with the Apple-Intelligence
/// pastels (purple → pink → blue → violet) for a hint of hue without
/// becoming a rainbow.
///
/// ## Light vs dark
///
/// - **Dark mode**: `.normal` blend — the inner halo blooms naturally
///   against the dark panel, full strength.
/// - **Light mode**: the whole stack is composited with `.plusLighter`
///   inside a `compositingGroup`, so over the near-white panel the strip
///   can only ever *add* light and never muddies toward grey; base opacity
///   is held a touch lower for an airy inner sheen.
///
/// ## Reduce Motion
///
/// The single `TimelineView(.animation(paused:))` is paused under
/// `accessibilityReduceMotion`; we then park the segment at a fixed
/// position with the breathing held at its mid value — a still, still-pretty
/// frame. No private Apple API is used; this is the documented, shader-free
/// SwiftUI approach (confirmed by [[apple-api-research-first]]).
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

    /// Length of the lit window as a fraction of the perimeter — the size
    /// of the "灯带" segment. ~0.2 reads as a clear travelling strip rather
    /// than a near-full ring.
    private static let segLen: Double = 0.2

    /// Seconds for one full lap of the perimeter.
    private static let lapPeriod: Double = 5.0

    /// Breathing period (seconds) — the slow brightness swell.
    private static let breathPeriod: Double = 3.4

    /// Non-uniform-speed amplitude. The head advances as
    /// `p = (φ + speedWarp·sin(2π φ)) mod 1`; this stays monotonic for
    /// `speedWarp < 1/2π ≈ 0.159`, so 0.12 gives a clear speed-up / ease-off
    /// without ever reversing.
    private static let speedWarp: Double = 0.12

    /// Where the parked segment sits under Reduce Motion (top-centre-ish).
    private static let parkedPhase: Double = 0.0

    /// The comet layers, head → tail → halo. Each is a trim of the rounded
    /// rect:
    ///   - `lengthScale` — fraction of `segLen` this piece spans (tail
    ///     pieces are shorter, sitting *behind* the head).
    ///   - `width`       — stroke line width.
    ///   - `blur`        — blur radius (the halo is fat and soft).
    ///   - `opacity`     — relative brightness (head brightest).
    private static let layers: [(lengthScale: Double,
                                 width: CGFloat,
                                 blur: CGFloat,
                                 opacity: Double)] = [
        (1.00, 14, 18, 0.55),   // inner halo — fat, soft, masked inward
        (0.85,  9,  7, 0.50),   // outer tail
        (0.55,  6,  3, 0.70),   // inner tail
        (0.30,  3,  0, 1.00),   // crisp bright head
    ]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let s = state(at: ctx.date.timeIntervalSinceReferenceDate)
            render(head: s.head, breath: s.breath)
        }
    }

    /// Resolve the travelling head position (non-uniform speed, looping) and
    /// the breathing multiplier for the given timeline instant. Frozen to a
    /// parked frame under Reduce Motion.
    private func state(at now: Double) -> (head: Double, breath: Double) {
        guard !reduceMotion else {
            return (Self.parkedPhase, 0.85)   // calm mid-breath, parked
        }
        let phi = (now / Self.lapPeriod).truncatingRemainder(dividingBy: 1)
        let head = wrap01(phi + Self.speedWarp * sin(2 * .pi * phi))
        let b = 0.5 - 0.5 * cos(2 * .pi * now / Self.breathPeriod)
        return (head, 0.7 + 0.3 * b)
    }

    @ViewBuilder
    private func render(head: Double, breath: Double) -> some View {
        let theme = (scheme == .dark) ? Self.darkTheme : Self.lightTheme
        let shape = RoundedRectangle(cornerRadius: cornerRadius,
                                      style: .continuous)

        ZStack {
            ForEach(Self.layers.indices, id: \.self) { i in
                let layer = Self.layers[i]
                // Each piece is the head's window, shortened from its
                // trailing edge so shorter pieces sit *behind* the head and
                // form the fading wake.
                let span = Self.segLen * layer.lengthScale
                CometStrip(shape: shape,
                           start: head,
                           length: span,
                           color: theme.core,
                           lineWidth: layer.width * intensity,
                           blur: layer.blur * intensity)
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
        /// The luminous comet core — a bright near-white with a pastel tint.
        let core: Color
        /// Per-scheme compositing.
        let blendMode: BlendMode
    }

    /// Dark: full-strength luminous core, normal blend — the inner halo
    /// blooms naturally against the dark panel.
    private static let darkTheme = Theme(
        baseOpacity: 0.95,
        core: rgb(0xEA, 0xE2, 0xFF),    // bright violet-white
        blendMode: .normal)

    /// Light: lower base opacity (an airy inner sheen) + `plusLighter` so
    /// the strip only brightens the white surface, staying clean.
    private static let lightTheme = Theme(
        baseOpacity: 0.8,
        core: rgb(0xC8, 0xA8, 0xFF),    // saturated-enough to read on white
        blendMode: .plusLighter)
}

// MARK: - Comet strip piece

/// One trim "piece" of the travelling light strip: the moving window
/// `[start, start + length]` along the rounded-rect perimeter, drawn with a
/// soft pastel gradient that fades from the tail up to the bright head.
///
/// The crux is **wrap-around**: `.trim(from:to:)` cannot express a window
/// that crosses the `1 → 0` seam in a single call, so when the window
/// overflows we draw it as two trims — `[start, 1]` and `[0, end − 1]` —
/// which butt together at the seam and read as one continuous strip.
///
/// The piece is **inset by half its line width before trimming** so the
/// stroke lands *inside* the edge (the `strokeBorder` effect — `strokeBorder`
/// itself isn't available after `.trim`, which drops `InsettableShape`
/// conformance); the caller additionally masks the whole stack to the filled
/// shape so any blur only spills inward.
private struct CometStrip: View {
    let shape: RoundedRectangle
    /// Trailing edge of this piece, in `0...1` along the perimeter.
    let start: Double
    /// Length of this piece as a fraction of the perimeter.
    let length: Double
    let color: Color
    let lineWidth: CGFloat
    let blur: CGFloat

    var body: some View {
        // Inset by half the width *before* trimming, so the stroke sits on
        // the interior of the edge (inner glow), like `strokeBorder`.
        let inset = shape.inset(by: lineWidth / 2)
        let end = start + length
        Group {
            if end <= 1.0 {
                piece(inset, from: start, to: end, headAtEnd: true)
            } else {
                // Wrap: split the window across the seam into two trims.
                piece(inset, from: start, to: 1.0, headAtEnd: false)
                piece(inset, from: 0.0, to: end - 1.0, headAtEnd: true)
            }
        }
        .blur(radius: blur)
    }

    /// A single non-wrapping trim. The gradient runs dim→bright so the head
    /// (high end of the window) is brightest and the tail fades to clear.
    @ViewBuilder
    private func piece(_ insetShape: some Shape,
                       from: Double, to: Double, headAtEnd: Bool) -> some View {
        insetShape
            .trim(from: from, to: to)
            .stroke(
                LinearGradient(
                    colors: [color.opacity(0.0), color],
                    startPoint: headAtEnd ? .leading : .trailing,
                    endPoint: headAtEnd ? .trailing : .leading),
                style: StrokeStyle(lineWidth: lineWidth,
                                   lineCap: .round))
    }
}

// MARK: - Helpers

/// Wrap a value into `[0, 1)`.
private func wrap01(_ x: Double) -> Double {
    let r = x.truncatingRemainder(dividingBy: 1)
    return r < 0 ? r + 1 : r
}

private func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
    Color(red: Double(r) / 255.0,
          green: Double(g) / 255.0,
          blue: Double(b) / 255.0)
}
