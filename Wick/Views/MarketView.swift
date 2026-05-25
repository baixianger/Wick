import SwiftUI

/// Top-level Market page — a "what's the world doing" view that
/// lives at the sidebar root next to Portfolio + Wicker. Scaffold
/// for now; the actual content (sector heatmap / indices /
/// movers / global macro snapshot) lands in a later iteration.
///
/// Per the new UX model, Market is a *passive* page — there's no
/// chat input here. The floating Wicker composer that sits over
/// every non-Wicker page handles all "ask the agent" interactions.
struct MarketView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                placeholderCard
            }
            // Match Portfolio's reference padding so every page
            // edges in by the same amount.
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .background(appleBackground(for: colorScheme))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Market")
                .font(.system(size: 32, weight: .bold))
            Text(Date.now.formatted(date: .complete, time: .omitted))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var placeholderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Coming soon")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text("This page will surface a sector heatmap, headline index "
                 + "performance, today's movers, and a global macro snapshot — "
                 + "a single \"what's the world doing\" view.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("In the meantime, ask Wicker — the floating composer in the "
                 + "bottom-right will route any question to a fresh chat.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 14)
    }
}
