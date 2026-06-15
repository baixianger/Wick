import Foundation

/// Default-on, NO-credentials social-sentiment source backed by the free public
/// StockTwits symbol stream (`StockTwitsClient`). Unlike the BYO X / 雪球
/// providers, StockTwits needs no key, no OAuth, and no logged-in session — it's
/// a free public endpoint — so it ships ON by default for every user:
///   • `requiresUserCredentials = false`
///   • `interactiveOnly = false`  (safe in the fixed/batch flow too)
///
/// US-listed equities ONLY. The client rejects CN/HK and exchange-suffixed
/// symbols up front; this provider surfaces that as a clean, clearly-labelled
/// empty read rather than fabricated chatter.
///
/// Mapping into the analyst's `SocialSentiment`:
///   • Each message → a `SocialPost`. The Bullish/Bearish tag (when present)
///     becomes a per-post `score` in `-1...1`, scaled by author reputation
///     (followers + likes) so a heavily-followed bull weighs more than a
///     drive-by. Tagless posts carry `score == nil` (no signal, not neutral).
///   • The `summary` reports the net bull/bear lean over the TAGGED posts only
///     (the share that actually voted), plus how many were tagged.
public struct StockTwitsSentimentProvider: SocialSentimentProvider {
    public let sourceName = "StockTwits"
    public let requiresUserCredentials = false
    public let interactiveOnly = false

    private let client: StockTwitsClient
    private let limit: Int

    public init(client: StockTwitsClient = StockTwitsClient(), limit: Int = 30) {
        self.client = client
        self.limit = limit
    }

    public func sentiment(symbol: String, asOf: Date) async throws -> SocialSentiment {
        // Non-US → empty, clearly labelled (never fabricate).
        guard StockTwitsClient.isUSSymbol(symbol.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return SocialSentiment(
                symbol: symbol, asOf: asOf, source: sourceName,
                summary: "StockTwits 仅支持美股标的。",
                posts: [])
        }

        let messages = await client.messages(symbol: symbol, limit: limit)
        guard !messages.isEmpty else {
            return SocialSentiment(
                symbol: symbol, asOf: asOf, source: sourceName,
                summary: "无可用 StockTwits 讨论（无内容 / 接口受限）。",
                posts: [])
        }

        let posts = messages.map { msg -> SocialPost in
            SocialPost(
                source: sourceName,
                text: Self.annotate(msg),
                score: Self.score(for: msg),
                createdAt: msg.createdAt)
        }

        return SocialSentiment(
            symbol: symbol, asOf: asOf, source: sourceName,
            summary: Self.summarize(messages),
            posts: posts)
    }

    // MARK: - Scoring

    /// Per-post sentiment in `-1...1`: sign from the Bullish/Bearish tag,
    /// magnitude from author reputation (a confidence weight, NOT certainty).
    /// Tagless posts return `nil` — they carry no directional signal and must
    /// not be counted as neutral 0.
    static func score(for msg: StockTwitsMessage) -> Double? {
        guard let tag = msg.sentiment else { return nil }
        let base: Double = (tag == .bullish) ? 1 : -1
        return base * reputationWeight(followers: msg.followers, likes: msg.likeCount)
    }

    /// Reputation → `0.5...1.0`. A floor of 0.5 keeps every tagged post
    /// meaningful; followers + likes lift it toward 1.0 on a log curve so a few
    /// power users don't drown out the crowd. (10 followers ≈ 0.5; ~1k ≈ 0.75;
    /// ~50k+ ≈ ~1.0.)
    static func reputationWeight(followers: Int, likes: Int) -> Double {
        let reach = Double(max(followers, 0)) + Double(max(likes, 0)) * 0.1
        guard reach > 0 else { return 0.5 }
        let scaled = log10(reach + 1) / log10(50_000)   // ~1.0 around 50k reach
        return 0.5 + 0.5 * min(max(scaled, 0), 1)
    }

    // MARK: - Rendering

    /// Prefix the body with its tag + reputation so the analyst reads the label
    /// inline (the `score` field is also set, but the text is what the LLM sees
    /// in the tool output's post list).
    static func annotate(_ msg: StockTwitsMessage) -> String {
        let body = msg.body.replacingOccurrences(of: "\n", with: " ")
        let who = msg.followers > 0 ? "@\(msg.username), \(msg.followers) followers" : "@\(msg.username)"
        if let tag = msg.sentiment {
            return "[\(tag == .bullish ? "Bullish" : "Bearish") · \(who)] \(body)"
        }
        return "[\(who)] \(body)"
    }

    /// Net read over the TAGGED posts (the ones that actually voted).
    static func summarize(_ messages: [StockTwitsMessage]) -> String {
        let tagged = messages.filter { $0.sentiment != nil }
        let total = messages.count
        guard !tagged.isEmpty else {
            return "\(total) 条讨论，均无 Bullish/Bearish 标记（无明确情绪倾向）。"
        }
        let bulls = tagged.filter { $0.sentiment == .bullish }.count
        let bears = tagged.count - bulls
        let bullPct = Int((Double(bulls) / Double(tagged.count) * 100).rounded())
        let lean: String
        if bullPct >= 60 { lean = "net bullish" }
        else if bullPct <= 40 { lean = "net bearish" }
        else { lean = "mixed / balanced" }
        return "\(lean), \(bullPct)% bullish — \(bulls) 多 / \(bears) 空 "
            + "（\(tagged.count)/\(total) 条带标记）。"
    }
}
