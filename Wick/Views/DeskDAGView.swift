import SwiftUI

/// Visual DAG of the multi-agent workflow.
///
/// Renders the four phases (Analysts → Research → Decision → Risk) as
/// avatar nodes connected by cubic-Bezier paths. Tap a node to select
/// it; the binding lets the parent display that contributor's
/// markdown alongside. Upstream-ancestor edges glow in accent when a
/// node is active so the user sees the chain of evidence at a glance.
///
/// Coordinates inside the canvas are stored as 0–1 fractions of the
/// container; `GeometryReader` resolves them to pixel positions, so
/// the chart scales fluidly with the pane width.
struct DeskDAGView: View {

    /// Currently selected node ID. `nil` = no selection (all edges
    /// rendered at base contrast).
    @Binding var selected: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                // Background phase bands — thin horizontal rules and a
                // left-aligned phase tag, like a stage marker.
                phaseBands(in: proxy.size)

                // Edges (Canvas, single pass for perf).
                Canvas { ctx, size in
                    for edge in Self.edges {
                        let a = position(edge.from, in: size)
                        let b = position(edge.to,   in: size)
                        let path = pathBetween(a, b, debate: edge.debate)
                        let active = isOnAncestorPath(edge)
                        let stroke: GraphicsContext.Shading
                        let width: CGFloat
                        let opacity: Double
                        if active {
                            stroke = .color(Color.accentColor)
                            width = 1.6
                            opacity = 1.0
                        } else if selected != nil {
                            stroke = .color(.secondary.opacity(0.18))
                            width = 1
                            opacity = 1
                        } else if edge.debate {
                            // Two-tone gradient look without literal
                            // gradient — paint twice with offset.
                            stroke = .color(.secondary.opacity(0.45))
                            width = 1.2
                            opacity = 0.75
                        } else {
                            stroke = .color(.secondary.opacity(0.35))
                            width = 1
                            opacity = 1
                        }
                        var resolved = ctx
                        resolved.opacity = opacity
                        if edge.debate {
                            // Dashed for the bull↔bear debate line.
                            var style = StrokeStyle(lineWidth: width)
                            style.dash = [4, 5]
                            resolved.stroke(path, with: stroke, style: style)
                        } else {
                            resolved.stroke(path, with: stroke,
                                            lineWidth: width)
                        }
                    }
                }

                // Nodes — positioned absolutely via .position(...).
                ForEach(Self.nodes) { node in
                    DeskNodeAvatar(
                        node: node,
                        isSelected: selected == node.id
                    )
                    .position(position(node.id, in: proxy.size))
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.28)) {
                            selected = (selected == node.id) ? nil : node.id
                        }
                    }
                }

                // "debate" tag floating between Bull and Bear.
                let bullPos = position("bull", in: proxy.size)
                let bearPos = position("bear", in: proxy.size)
                Text("debate")
                    .font(.system(size: 10, design: .serif).italic())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(.background.opacity(0.8))
                            .overlay(Capsule().strokeBorder(
                                Color.secondary.opacity(0.25),
                                lineWidth: 0.5))
                    )
                    .position(x: (bullPos.x + bearPos.x) / 2,
                              y: bullPos.y - 38)
            }
            .frame(width: w, height: h)
        }
        .padding(.vertical, 12)
        .padding(.leading, 78)  // breathing room for phase tags
        .padding(.trailing, 12)
    }

    // MARK: - Phase bands

    @ViewBuilder
    private func phaseBands(in size: CGSize) -> some View {
        ForEach(Self.phases) { phase in
            let y = phase.y * size.height
            HStack(spacing: 8) {
                Circle()
                    .fill(phase.color)
                    .frame(width: 5, height: 5)
                    .shadow(color: phase.color, radius: 4)
                Text(phase.name.uppercased())
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.18 * 8)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(.regularMaterial)
            )
            .position(x: -42, y: y)
        }
    }

    // MARK: - Geometry

    private func position(_ id: String, in size: CGSize) -> CGPoint {
        guard let n = Self.nodes.first(where: { $0.id == id }) else {
            return .zero
        }
        return CGPoint(x: n.x * size.width, y: n.y * size.height)
    }

    /// Cubic-Bezier path between two node centers. Vertical flow gets
    /// a smooth S; the debate edge arcs up between Bull and Bear so
    /// it doesn't visually collide with the body-of-the-chart paths.
    private func pathBetween(_ a: CGPoint, _ b: CGPoint,
                              debate: Bool) -> Path
    {
        var path = Path()
        if debate {
            // Anchor at left/right edges of the avatars (~36pt from
            // center) and arc above.
            let r: CGFloat = 36
            let dir = b.x > a.x ? 1.0 : -1.0
            let start = CGPoint(x: a.x + dir * r, y: a.y)
            let end   = CGPoint(x: b.x - dir * r, y: b.y)
            let c1 = CGPoint(x: start.x + dir * 60, y: start.y - 50)
            let c2 = CGPoint(x: end.x   - dir * 60, y: end.y   - 50)
            path.move(to: start)
            path.addCurve(to: end, control1: c1, control2: c2)
        } else {
            let topGap: CGFloat = 36
            let start = CGPoint(x: a.x, y: a.y + topGap)
            let end   = CGPoint(x: b.x, y: b.y - topGap)
            let dy = end.y - start.y
            let c1 = CGPoint(x: start.x, y: start.y + dy * 0.5)
            let c2 = CGPoint(x: end.x,   y: end.y   - dy * 0.5)
            path.move(to: start)
            path.addCurve(to: end, control1: c1, control2: c2)
        }
        return path
    }

    // MARK: - Ancestor highlighting

    private func isOnAncestorPath(_ edge: DeskEdge) -> Bool {
        guard let sel = selected else { return false }
        let reachable = ancestors(of: sel)
        return reachable.contains(edge.from) && reachable.contains(edge.to)
    }

    private func ancestors(of id: String) -> Set<String> {
        var set: Set<String> = [id]
        var changed = true
        while changed {
            changed = false
            for e in Self.edges {
                if set.contains(e.to) && !set.contains(e.from) {
                    set.insert(e.from)
                    changed = true
                }
            }
        }
        return set
    }

    // MARK: - Static layout catalogue

    static let nodes: [DeskNode] = [
        // Analysts row
        .init(id: "fund",   role: "Fundamental Analyst",
              icon: "building.columns",
              color: .teal,
              x: 0.13, y: 0.13),
        .init(id: "tech",   role: "Technical Analyst",
              icon: "chart.xyaxis.line",
              color: .blue,
              x: 0.39, y: 0.13),
        .init(id: "sent",   role: "Sentiment Analyst",
              icon: "bubble.left.and.bubble.right",
              color: .purple,
              x: 0.62, y: 0.13),
        .init(id: "news",   role: "News Analyst",
              icon: "newspaper",
              color: .indigo,
              x: 0.88, y: 0.13),
        // Research row
        .init(id: "bull",   role: "Bull Researcher",
              icon: "arrow.up.forward.circle",
              color: .green,
              x: 0.37, y: 0.42),
        .init(id: "bear",   role: "Bear Researcher",
              icon: "arrow.down.forward.circle",
              color: .red,
              x: 0.63, y: 0.42),
        // Decision
        .init(id: "trader", role: "Trader",
              icon: "checkmark.seal",
              color: .orange,
              x: 0.50, y: 0.69),
        // Risk
        .init(id: "risk",   role: "Risk Manager",
              icon: "shield.lefthalf.filled",
              color: .gray,
              x: 0.50, y: 0.90),
    ]

    static let edges: [DeskEdge] = [
        // Every analyst feeds both researchers
        .init(from: "fund", to: "bull"),
        .init(from: "tech", to: "bull"),
        .init(from: "sent", to: "bull"),
        .init(from: "news", to: "bull"),
        .init(from: "fund", to: "bear"),
        .init(from: "tech", to: "bear"),
        .init(from: "sent", to: "bear"),
        .init(from: "news", to: "bear"),
        // Bull ↔ Bear debate
        .init(from: "bull", to: "bear", debate: true),
        // Both researchers → trader
        .init(from: "bull", to: "trader"),
        .init(from: "bear", to: "trader"),
        // Trader → risk
        .init(from: "trader", to: "risk"),
    ]

    static let phases: [DeskPhase] = [
        .init(name: "Analysts", y: 0.13, color: .blue),
        .init(name: "Research", y: 0.42, color: .indigo),
        .init(name: "Decision", y: 0.69, color: .orange),
        .init(name: "Risk",     y: 0.90, color: .gray),
    ]

    /// Map an `AgentMessage.role` string to a node ID. Returns nil
    /// for roles that don't have a DAG node (defensive — the engine's
    /// role catalogue should be the union of these).
    static func nodeId(for role: String) -> String? {
        switch role {
        case "Fundamental Analyst": return "fund"
        case "Technical Analyst":   return "tech"
        case "Sentiment Analyst":   return "sent"
        case "News Analyst":        return "news"
        case "Bull Researcher":     return "bull"
        case "Bear Researcher":     return "bear"
        case "Trader":              return "trader"
        case "Risk Manager":        return "risk"
        default:                    return nil
        }
    }
}

// MARK: - Supporting types

struct DeskNode: Identifiable, Hashable {
    let id: String
    let role: String
    let icon: String
    let color: Color
    let x: Double   // 0..1, fraction of width
    let y: Double   // 0..1, fraction of height
}

struct DeskEdge: Hashable {
    let from: String
    let to: String
    var debate: Bool = false
}

struct DeskPhase: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let y: Double
    let color: Color
}

// MARK: - Avatar view

/// Circular avatar node — radial-gradient fill in the role colour,
/// SF Symbol centered. Selected state adds an outer ring + glow.
struct DeskNodeAvatar: View {
    let node: DeskNode
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                node.color.opacity(0.55),
                                node.color.opacity(0.10),
                            ],
                            center: .topLeading,
                            startRadius: 4,
                            endRadius: 56)
                    )
                Circle()
                    .strokeBorder(node.color.opacity(0.7),
                                  lineWidth: 1)
                Image(systemName: node.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(node.color)
                    .shadow(color: node.color.opacity(0.6), radius: 4)
            }
            .frame(width: 52, height: 52)
            .overlay(
                Circle()
                    .strokeBorder(node.color, lineWidth: 1)
                    .scaleEffect(1.18)
                    .opacity(isSelected ? 1 : 0)
                    .animation(.easeInOut(duration: 0.3), value: isSelected)
            )
            .shadow(color: isSelected
                    ? node.color.opacity(0.6)
                    : .black.opacity(0.4),
                    radius: isSelected ? 16 : 8)
            .scaleEffect(isSelected ? 1.06 : 1.0)
            .animation(.spring(duration: 0.3), value: isSelected)

            Text(node.role)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .frame(width: 88)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
    }
}
