import SwiftUI

/// Apple-Intelligence-style border glow — faithful SwiftUI port of
/// the React `border-beam` library
/// (https://github.com/Jakubantalik/border-beam).
///
/// Three structural ingredients, all from `styles.ts` verbatim:
///
/// 1. **Nine fixed-position radial ellipses** painted in element-local
///    space (positions in % of bounds, sizes in points). This gives
///    the *localised* purple / pink / blue / red / orange "spike"
///    feel you see on the reference demo — emphatically not a
///    uniform rainbow ring.
/// 2. **A rotating conic sweep** of white (dark mode) or black
///    (light mode), additively brightening one arc of the perimeter
///    at a time. This is the "highlight that travels along the
///    border" element of the effect.
/// 3. **A ring-donut mask** that confines all of the above to the
///    rounded-rectangle outline at the requested cornerRadius.
///
/// On top of the composite we apply:
/// - **±30° hue oscillation** over 12 s (slow colour drift, à la
///   border-beam's `beam-hue-shift` keyframes).
/// - **Per-theme saturation + stroke opacity** straight from
///   `sizeThemePresets.md.dark` / `.light`.
///
/// No public Apple API exists for this effect as of WWDC25 — confirmed
/// by [[apple-api-research-first]]. The hand-rolled implementation
/// matches Apple's surface visual via a totally separate technique
/// (positional ellipses + sweep) — same illusion, no Metal needed.

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

// MARK: - Spike spec

/// One radial-gradient ellipse from the `colorful.border` stack in
/// border-beam's `styles.ts` (lines 90-101). Positions are normalised
/// (multiply by bounds.width / bounds.height). Sizes are in points
/// (rx, ry — half-extents of the ellipse).
private struct Spike {
    let color: Color
    /// 0…1 (or beyond, including negative — CSS allows that) along
    /// the element's width / height.
    let x: Double
    let y: Double
    /// Half-extents in points.
    let rx: CGFloat
    let ry: CGFloat
}

// MARK: - The glow itself

private struct IntelligenceGlow: View {
    let cornerRadius: CGFloat
    let intensity: Double
    let reduceMotion: Bool

    @Environment(\.colorScheme) private var scheme

    /// Verbatim from `colorPalettes.colorful.border` in styles.ts —
    /// `<x%> <y%>` positions, `<rx>px <ry>px` sizes. Same stack used
    /// for both dark and light themes; only the overall opacity /
    /// saturation differ between themes (per `sizeThemePresets.md`).
    private static let spikes: [Spike] = [
        Spike(color: rgb(255,  50, 100), x: 0.330, y: -0.074, rx: 35, ry: 20),
        Spike(color: rgb( 40, 140, 255), x: 0.120, y: -0.050, rx: 30, ry: 17.5),
        Spike(color: rgb( 50, 200,  80), x: 0.021, y:  0.683, rx: 20, ry: 35),
        Spike(color: rgb( 30, 185, 170), x: 0.021, y:  0.683, rx: 10, ry: 17.5),
        Spike(color: rgb(100,  70, 255), x: 0.744, y:  1.000, rx: 90, ry: 16),
        Spike(color: rgb( 40, 140, 255), x: 0.550, y:  1.000, rx: 42.5, ry: 13),
        Spike(color: rgb(255, 120,  40), x: 0.939, y:  0.000, rx: 37, ry: 16),
        Spike(color: rgb(240,  50, 180), x: 1.000, y:  0.271, rx: 13, ry: 21),
        Spike(color: rgb(180,  40, 240), x: 1.000, y:  0.271, rx: 26, ry: 24),
    ]

    /// Beam sweep rotation period. `border-beam` defaults to ~1.96 s
    /// for `md`; that's punchy but visually fine on the demo. Kept
    /// here as a tunable.
    private static let sweepPeriod: Double = 2.4

    /// Spike sizes in styles.ts (rx/ry) are absolute pixels designed
    /// for a button-sized element (~256pt wide, ~56pt tall — the demo
    /// box on beam.jakubantalik.com). When our host view is wider (the
    /// 720pt hero composer) or taller, painting those fixed-size
    /// ellipses leaves huge dead zones on the long edges — the glow
    /// degenerates into four faint corner blobs. We scale each spike's
    /// rx by width/refW and ry by height/refH so the ellipses keep
    /// pace with the bounds, restoring the "every part of the
    /// perimeter is alive" feel of the React reference at any aspect
    /// ratio. Floor of 1.0 — never shrink below the styles.ts spec
    /// for small targets like the typing indicator.
    private static let referenceWidth: CGFloat = 256
    private static let referenceHeight: CGFloat = 56

    /// Hue oscillation period (12 s) and ±range (30°) — matches
    /// `beam-hue-shift` keyframes in styles.ts (lines 918-925).
    private static let hueCyclePeriod: Double = 12.0
    private static let hueRangeDegrees: Double = 30.0

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let now = ctx.date.timeIntervalSinceReferenceDate
            let sweepAngle: Double = reduceMotion
                ? 0.0
                : (now.truncatingRemainder(dividingBy: Self.sweepPeriod)
                    / Self.sweepPeriod) * 360.0
            // Sin-wave oscillation, NOT a linear sweep — matches the
            // `0% → 50% → 100%` symmetric keyframes (back-and-forth
            // around the neutral colour).
            let hueT: Double = reduceMotion
                ? 0.0
                : sin(now / Self.hueCyclePeriod * 2.0 * .pi)
            let hueDegrees = hueT * Self.hueRangeDegrees
            render(sweepAngle: sweepAngle, hueDegrees: hueDegrees)
        }
    }

    @ViewBuilder
    private func render(sweepAngle: Double, hueDegrees: Double) -> some View {
        let theme = (scheme == .dark) ? Self.darkTheme : Self.lightTheme
        let sweepColor: Color = (scheme == .dark) ? .white : .black
        let shape = RoundedRectangle(cornerRadius: cornerRadius,
                                      style: .continuous)

        // border-beam composites THREE stroke layers, not one. Without
        // all three the effect collapses into a "rainbow frame" instead
        // of "the rounded rect is glowing":
        //
        //   1. Outer BLOOM — fattest stroke + heavy blur. Bleeds well
        //      outside the rect's outline; this is the dominant visual
        //      element on the demo site (bloomOpacity is the highest
        //      of the three — 0.8 dark / 0.54 light per `sizeThemePresets`).
        //   2. Inner GLOW — medium stroke + light blur. Carries colour
        //      onto the inner edge of the rect.
        //   3. Crisp STROKE — thin stroke + the rotating conic sweep.
        //      The actual hard edge with the travelling highlight.
        //
        // All three reuse the same 9-spike canvas; only stroke width,
        // blur radius, and opacity differ.
        ZStack {
            spikesCanvas
                .mask { shape.stroke(lineWidth: theme.bloomStrokeWidth) }
                .blur(radius: theme.bloomBlur)
                .opacity(theme.bloomOpacity * intensity)

            spikesCanvas
                .mask { shape.stroke(lineWidth: theme.innerStrokeWidth) }
                .blur(radius: theme.innerBlur)
                .opacity(theme.innerOpacity * intensity)

            ZStack {
                spikesCanvas
                AngularGradient(
                    stops: theme.sweepStops(color: sweepColor),
                    center: .center,
                    angle: .degrees(sweepAngle))
            }
            .mask { shape.stroke(lineWidth: theme.crispStrokeWidth) }
            .opacity(theme.strokeOpacity * intensity)
        }
        .saturation(theme.saturation)
        .hueRotation(.degrees(hueDegrees))
    }

    /// The 9 radial-gradient ellipses, painted into a Canvas. Reused
    /// by all three stroke layers (bloom / inner / crisp); only the
    /// mask + blur + opacity downstream differ.
    private var spikesCanvas: some View {
        GeometryReader { geo in
            Canvas(opaque: false) { ctx, size in
                // Scale spike radii with the bounds so wide / tall
                // containers (hero composer, banners) keep the whole
                // perimeter painted. `max(1, …)` preserves the
                // original styles.ts feel for small targets.
                let sx = max(1.0, size.width  / Self.referenceWidth)
                let sy = max(1.0, size.height / Self.referenceHeight)
                for spike in Self.spikes {
                    let rx = spike.rx * sx
                    let ry = spike.ry * sy
                    let center = CGPoint(x: size.width * spike.x,
                                         y: size.height * spike.y)
                    let rect = CGRect(x: center.x - rx,
                                      y: center.y - ry,
                                      width: rx * 2,
                                      height: ry * 2)
                    let gradient = Gradient(colors: [
                        spike.color, spike.color.opacity(0.0)
                    ])
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .radialGradient(
                            gradient,
                            center: center,
                            startRadius: 0,
                            endRadius: max(rx, ry)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Themes

    private struct Theme {
        // Stroke widths per layer. Bloom is fat → extends well outside
        // the rect outline once blurred; inner is medium; crisp is a
        // thin hairline.
        let bloomStrokeWidth: CGFloat
        let innerStrokeWidth: CGFloat
        let crispStrokeWidth: CGFloat
        // Per-layer blur (only bloom + inner get blurred; crisp stays
        // pixel-sharp so the edge has a real visible line).
        let bloomBlur: CGFloat
        let innerBlur: CGFloat
        // Opacities verbatim from border-beam's `sizeThemePresets.md`.
        let bloomOpacity: Double
        let innerOpacity: Double
        let strokeOpacity: Double
        // Saturation + sweep peak alpha — tuned per mode.
        let saturation: Double
        let sweepPeak: Double

        /// Conic-sweep stops matching `styles.ts:929-953`. Scaled by
        /// `sweepPeak` so per-theme tone is a global alpha multiplier,
        /// not a re-shaping of the falloff curve.
        func sweepStops(color: Color) -> [Gradient.Stop] {
            let p = sweepPeak
            return [
                .init(color: .clear, location: 0.00),
                .init(color: .clear, location: 0.54),
                .init(color: color.opacity(p * 0.133), location: 0.57),
                .init(color: color.opacity(p * 0.400), location: 0.60),
                .init(color: color.opacity(p * 0.800), location: 0.63),
                .init(color: color.opacity(p * 1.000), location: 0.66),
                .init(color: color.opacity(p * 0.800), location: 0.69),
                .init(color: color.opacity(p * 0.400), location: 0.72),
                .init(color: color.opacity(p * 0.133), location: 0.75),
                .init(color: .clear, location: 0.78),
                .init(color: .clear, location: 1.00),
            ]
        }
    }

    /// Dark = vibrant; light = pre-darkened/desaturated.
    ///
    /// **Critical correction (round 5):** all three rings are now
    /// HAIRLINES. border-beam ships `borderWidth: 1px` — every layer's
    /// pre-blur ring is one pixel wide. The visible glow is almost
    /// entirely the BLUR output of those hairlines (the bloom layer's
    /// `filter: blur(8px)` spreads a 1-px painted line into a ~16-pt
    /// soft halo). Earlier iterations stroked thick rings (22pt) and
    /// blurred them lightly — which produced a "rainbow frame" with
    /// visibly offset inner / outer corner curvatures, exactly the
    /// "the corners are wrong" the user flagged. Thin strokes mean the
    /// inner and outer edges of the visible band are effectively the
    /// same path → corners follow the rounded-rect's curvature
    /// exactly.
    private static let darkTheme = Theme(
        bloomStrokeWidth: 2,       // tiny ring → blur does the work
        innerStrokeWidth: 1.5,
        crispStrokeWidth: 1,       // hairline edge line
        bloomBlur: 12,             // wide halo
        innerBlur: 4,
        bloomOpacity: 0.8,
        innerOpacity: 0.7,
        strokeOpacity: 0.48,
        saturation: 1.2,
        sweepPeak: 0.75)
    private static let lightTheme = Theme(
        bloomStrokeWidth: 2,
        innerStrokeWidth: 1.5,
        crispStrokeWidth: 1,
        bloomBlur: 10,
        innerBlur: 3.5,
        bloomOpacity: 0.54,
        innerOpacity: 0.46,
        strokeOpacity: 0.33,
        saturation: 0.70,
        sweepPeak: 0.40)
}

// MARK: - Helpers

private func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
    Color(red: Double(r) / 255.0,
          green: Double(g) / 255.0,
          blue: Double(b) / 255.0)
}
