import SwiftUI
import TradingFloor

/// Social data comes from configured APIs; community websites open externally.
struct SocialView: View {
    let ticker: Ticker
    @Environment(\.openURL) private var openURL
    @State private var stocktwitsModel = StockTwitsModel()

    private var isStockTwitsEligible: Bool { StockTwitsClient.isUSSymbol(ticker.symbol) }
    private var xueqiuURL: URL? {
        guard let symbol = CNSymbol.xueqiuSymbol(ticker.symbol) else { return nil }
        return URL(string: "https://xueqiu.com/S/\(symbol)")
    }

    private var xURL: URL? {
        var components = URLComponents(string: "https://x.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: "$" + ticker.symbol),
                                 URLQueryItem(name: "f", value: "live")]
        return components.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let url = xueqiuURL {
                Link(destination: url) {
                    Label("View on Xueqiu", systemImage: "arrow.up.right.square")
                }
                Text("Opens in your default browser. Sign in there if needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isStockTwitsEligible {
                if let url = xURL {
                    Link(destination: url) { Label("View on X", systemImage: "arrow.up.right.square") }
                }
                AdanosSection(symbol: ticker.symbol)
                stocktwitsSection
            } else if xueqiuURL == nil {
                Text("No social data source is available for this market.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: ticker.id) {
            if isStockTwitsEligible { await stocktwitsModel.load(symbol: ticker.symbol) }
        }
    }

    @ViewBuilder
    private var stocktwitsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            stocktwitsSectionHeader
            stocktwitsContent
        }
    }

    /// Header row: StockTwits source label + the "as of" timestamp + refresh.
    private var stocktwitsSectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            sourceBadge(text: "ST", tint: greenTint)
            Text("StockTwits")
                .font(.system(size: 18, weight: .semibold))
            if let asOf = stocktwitsModel.asOf {
                Text("· as of \(asOf.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            stocktwitsRefreshButton
        }
    }

    /// State machine inside the StockTwits section: loading → empty → cards.
    /// No not-connected state — the endpoint is public.
    @ViewBuilder
    private var stocktwitsContent: some View {
        if stocktwitsModel.isLoading {
            stocktwitsLoadingState
        } else if stocktwitsModel.messages.isEmpty {
            stocktwitsEmptyState
        } else {
            stocktwitsPostList
        }
    }

    /// Posts → card list. The outer DetailView already provides a ScrollView, so
    /// we lay the cards out in a plain VStack and let that scroll.
    private var stocktwitsPostList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(stocktwitsModel.messages) { message in
                stocktwitsPostCard(message)
            }
        }
    }

    private var stocktwitsLoadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading StockTwits discussion…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    /// Nothing to show (no posts, or the public endpoint had nothing / failed).
    private var stocktwitsEmptyState: some View {
        emptyCard(icon: "bubble.left.and.bubble.right",
                  title: "No discussion",
                  message: stocktwitsModel.didLoadOnce
                      ? String(localized: "StockTwits returned no recent discussion for this ticker. Try refreshing later.", locale: LocaleHolder.current)
                      : String(localized: "Tap refresh to load StockTwits discussion for this ticker.", locale: LocaleHolder.current)) {
            Button {
                Task { await stocktwitsModel.refresh(symbol: ticker.symbol) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(LiquidGlassButtonStyle(prominent: true))
        }
    }

    /// One StockTwits message card — author (name + @username), body, a
    /// Bullish/Bearish sentiment badge when present, relative time, and a subtle
    /// followers/likes footer. Tapping opens the author's StockTwits profile.
    /// Glass surface, mirroring the 雪球 / X cards.
    @ViewBuilder
    private func stocktwitsPostCard(_ message: StockTwitsMessage) -> some View {
        let profileURL = Self.stocktwitsProfileURL(username: message.username)
        let tappable = profileURL != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text(message.name.isEmpty
                     ? String(localized: "StockTwits user", locale: LocaleHolder.current)
                     : message.name)
                    .font(.system(size: 13, weight: .semibold))
                if !message.username.isEmpty {
                    Text("@\(message.username)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                sourceBadge(text: "ST", tint: greenTint)
                if let sentiment = message.sentiment {
                    sentimentBadge(sentiment)
                }
                Spacer(minLength: 0)
                Text(Self.relativeFormatter.localizedString(for: message.createdAt, relativeTo: Date()))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(message.body)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 16) {
                Label("\(message.followers)", systemImage: "person.2")
                Label("\(message.likeCount)", systemImage: "hand.thumbsup")
                Spacer(minLength: 0)
                if tappable {
                    Image(systemName: "arrow.up.forward.square")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 12)
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture {
            if let url = profileURL { openURL(url) }
        }
        .help(tappable ? String(localized: "Open author profile in browser", locale: LocaleHolder.current) : "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.name.isEmpty ? "StockTwits 用户" : message.name): \(message.body)")
        .accessibilityAddTraits(tappable ? .isLink : [])
    }

    /// Small Bullish / Bearish pill — green for bullish, red for bearish. Only
    /// rendered when the author attached a tag (`sentiment != nil`). Semantic
    /// colours only, matching the `sourceBadge` glass-safety posture.
    private func sentimentBadge(_ sentiment: StockTwitsSentiment) -> some View {
        let isBull = sentiment == .bullish
        let tint: Color = isBull ? .green : .red
        let text = isBull
            ? String(localized: "Bullish", locale: LocaleHolder.current)
            : String(localized: "Bearish", locale: LocaleHolder.current)
        let icon = isBull ? "arrow.up.right" : "arrow.down.right"
        return Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    private var stocktwitsRefreshButton: some View {
        Button {
            Task { await stocktwitsModel.refresh(symbol: ticker.symbol) }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.plain)
        .disabled(stocktwitsModel.isLoading)
        .help("Refresh StockTwits discussion")
        .accessibilityLabel("Refresh")
    }

    /// Build the `https://stocktwits.com/<username>` profile URL for a message
    /// author. `nil` for an empty / malformed username, so the card renders
    /// non-tappable. Mirrors `xProfileURL`.
    private static func stocktwitsProfileURL(username: String) -> URL? {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }
        return URL(string: "https://stocktwits.com/\(trimmed)")
    }

    // MARK: - Shared pieces

    /// Reusable empty / state card. `action` slots the primary affordance (or an
    /// `EmptyView`) under the explainer text.
    @ViewBuilder
    private func emptyCard<Action: View>(
        icon: String,
        title: LocalizedStringKey,
        message: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            action()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .liquidGlass(cornerRadius: 14)
    }

    /// Small source-label pill (雪球 / X). Semantic colours only, so the known
    /// glass-appearance-lag issue doesn't strand a hardcoded tone on a scheme
    /// flip.
    private func sourceBadge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    private var greenTint: Color { .green }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - StockTwits view model

/// View-local cache + fetch state for the Social tab's StockTwits messages. A
/// sibling of `SocialModel` / `XSocialModel`, but credential-free: StockTwits is
/// a free public endpoint, so there's no session to probe and no login gate —
/// `load` just calls the Foundation-only `StockTwitsClient`. Keyed by `symbol +
/// calendar-day` so re-selecting the tab within the same day reuses the last
/// result instead of re-hitting StockTwits. `@Observable` so the view tracks
/// `isLoading` / `messages` / `asOf` transitions.
@Observable
@MainActor
final class StockTwitsModel {
    /// The messages currently shown (newest first, as StockTwits returns them).
    private(set) var messages: [StockTwitsMessage] = []
    /// In-flight fetch flag, drives the spinner + disables refresh.
    private(set) var isLoading = false
    /// When the shown messages were fetched — surfaces the "as of <time>" label.
    private(set) var asOf: Date?
    /// True once any fetch (even an empty one) has completed, so the empty state
    /// can distinguish "not loaded yet" from "loaded, StockTwits had nothing".
    private(set) var didLoadOnce = false

    /// Cache key of the currently-held messages (`symbol|yyyy-ddd`).
    private var cacheKey: String?

    /// The shared public client — no credentials, no per-call config.
    private let client = StockTwitsClient()

    /// Fetch on first appear. No-op (cache hit) when we already hold today's
    /// messages for this symbol; otherwise loads directly (no session probe).
    func load(symbol: String) async {
        let key = Self.key(symbol: symbol)
        if cacheKey == key, !messages.isEmpty { return }   // same-day cache hit
        await fetch(symbol: symbol, key: key)
    }

    /// User-triggered refresh — always re-fetches (bypasses the same-day cache),
    /// since the user explicitly asked for fresh data.
    func refresh(symbol: String) async {
        await fetch(symbol: symbol, key: Self.key(symbol: symbol))
    }

    private func fetch(symbol: String, key: String) async {
        isLoading = true
        let fetched = await client.messages(symbol: symbol)
        isLoading = false
        didLoadOnce = true
        cacheKey = key
        asOf = Date()
        messages = fetched
    }

    /// `symbol|<year>-<day-of-year>` — stable within a calendar day.
    private static func key(symbol: String) -> String {
        let c = Calendar.current.dateComponents([.year, .dayOfYear], from: Date())
        return "\(symbol)|\(c.year ?? 0)-\(c.dayOfYear ?? 0)"
    }
}
