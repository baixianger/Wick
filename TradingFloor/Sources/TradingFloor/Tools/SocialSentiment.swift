import Foundation

/// One social/news item contributing to a sentiment read.
public struct SocialPost: Sendable, Codable {
    public let source: String        // "Finnhub", "X", "Reddit", "StockTwits"
    public let text: String
    public let score: Double?         // optional per-item sentiment, -1...1
    public let createdAt: Date?
    public init(source: String, text: String, score: Double? = nil, createdAt: Date? = nil) {
        self.source = source; self.text = text; self.score = score; self.createdAt = createdAt
    }
}

public struct SocialSentiment: Sendable, Codable {
    public let symbol: String
    public let asOf: Date
    public let source: String
    public let summary: String        // net read, e.g. "net positive, 62% bullish"
    public let posts: [SocialPost]
    public init(symbol: String, asOf: Date, source: String, summary: String, posts: [SocialPost]) {
        self.symbol = symbol; self.asOf = asOf; self.source = source
        self.summary = summary; self.posts = posts
    }
}

/// A social-sentiment source. Concrete implementations live in the HOST app
/// (Wick), not this package — because X/Reddit need OAuth + Keychain, which
/// are app-layer concerns. The package only defines the seam + a stub.
///
/// Guardrails are expressed in the type so the host can enforce them:
/// - `requiresUserCredentials`: X/Reddit = true (the user supplies their own
///   key); a licensed aggregator like Finnhub = false.
/// - `interactiveOnly`: BYO X/Reddit must NOT run in the server-side / fixed
///   batch flow — only when the user drives an interactive session.
public protocol SocialSentimentProvider: Sendable {
    var sourceName: String { get }
    var requiresUserCredentials: Bool { get }
    var interactiveOnly: Bool { get }
    func sentiment(symbol: String, asOf: Date) async throws -> SocialSentiment
}

public extension SocialSentimentProvider {
    var requiresUserCredentials: Bool { false }
    var interactiveOnly: Bool { false }
}

/// Aggregates one or more providers. The host decides which to include:
/// Finnhub by default; the user's own X / Reddit providers only when they've
/// supplied credentials AND the run is interactive. Providers that error
/// (rate limit, bad key) are skipped, not fatal — sentiment is best-effort.
public struct SocialSentimentTool: AgentTool {
    public let providers: [any SocialSentimentProvider]
    /// Set by the host: false for the fixed/batch flow so `interactiveOnly`
    /// providers (BYO X/Reddit) are excluded.
    public let interactive: Bool

    public init(providers: [any SocialSentimentProvider], interactive: Bool) {
        self.providers = providers
        self.interactive = interactive
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: "get_social_sentiment",
            description: "Aggregate recent social/news sentiment for a ticker from the "
                + "configured sources. Returns a net read plus representative posts.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "symbol": { "type": "string", "description": "Ticker symbol, e.g. NVDA" }
              },
              "required": ["symbol"]
            }
            """
        )
    }

    private struct Args: Decodable { let symbol: String }

    public func call(arguments: Data) async throws -> String {
        let symbol = try JSONDecoder().decode(Args.self, from: arguments).symbol
        let usable = providers.filter { interactive || !$0.interactiveOnly }

        var blocks: [String] = []
        for provider in usable {
            do {
                let s = try await provider.sentiment(symbol: symbol, asOf: .now)
                let lines = s.posts.prefix(5).map { "  · [\($0.source)] \($0.text)" }
                blocks.append("[\(s.source)] \(s.summary)\n" + lines.joined(separator: "\n"))
            } catch {
                // Best-effort: note the gap, keep going.
                blocks.append("[\(provider.sourceName)] unavailable (\(error.localizedDescription))")
            }
        }
        return blocks.isEmpty ? "No social-sentiment sources configured." : blocks.joined(separator: "\n\n")
    }
}

/// Deterministic stand-in for tests/previews — no network, no credentials.
public struct StubSocialSentimentProvider: SocialSentimentProvider {
    public let sourceName = "Stub"
    public init() {}
    public func sentiment(symbol: String, asOf: Date) async throws -> SocialSentiment {
        SocialSentiment(
            symbol: symbol, asOf: asOf, source: sourceName,
            summary: "net mildly positive (sample)",
            posts: [SocialPost(source: "Stub", text: "Sample bullish chatter post-launch.", score: 0.4)]
        )
    }
}
