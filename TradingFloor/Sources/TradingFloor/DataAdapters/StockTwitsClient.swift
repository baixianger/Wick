import Foundation

/// A StockTwits message author. Carried verbatim so a future Social-page UI can
/// render the byline (avatar + name + follower/like reputation) without a second
/// lookup.
public struct StockTwitsAuthor: Sendable, Hashable, Codable {
    public let username: String
    public let name: String
    public let avatarURL: URL?
    public let followers: Int
    public let likeCount: Int

    public init(username: String, name: String, avatarURL: URL?, followers: Int, likeCount: Int) {
        self.username = username
        self.name = name
        self.avatarURL = avatarURL
        self.followers = followers
        self.likeCount = likeCount
    }
}

/// The Bullish / Bearish tag StockTwits users may attach to a post. Many posts
/// carry no tag at all (the upstream `entities.sentiment` is `null`), so the
/// label is modelled as optional everywhere it appears.
public enum StockTwitsSentiment: String, Sendable, Hashable, Codable {
    case bullish
    case bearish
}

/// One StockTwits message about a ticker. PUBLIC + ergonomic so BOTH the
/// sentiment analyst (`StockTwitsSentimentProvider`) AND a future Social-page UI
/// consume the same shape. Foundation-only; no platform types leak in.
public struct StockTwitsMessage: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    public let body: String
    public let createdAt: Date
    /// `nil` when the author attached no Bullish/Bearish tag (common).
    public let sentiment: StockTwitsSentiment?
    public let author: StockTwitsAuthor
    /// Cashtags the post is filed under (e.g. `["AAPL", "MSFT"]`).
    public let symbols: [String]

    public init(id: Int, body: String, createdAt: Date,
                sentiment: StockTwitsSentiment?, author: StockTwitsAuthor,
                symbols: [String]) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.sentiment = sentiment
        self.author = author
        self.symbols = symbols
    }

    // Convenience passthroughs for UI/call sites that don't want to reach
    // through `author`.
    public var username: String { author.username }
    public var name: String { author.name }
    public var avatarURL: URL? { author.avatarURL }
    public var followers: Int { author.followers }
    public var likeCount: Int { author.likeCount }
}

/// Reads the public, no-auth StockTwits symbol stream:
///
///   `GET https://api.stocktwits.com/api/2/streams/symbol/{SYMBOL}.json`
///
/// No API key, no OAuth — a free public endpoint, so this can be a default
/// (non-BYO) data source. Foundation-only (builds inside the Linux-clean
/// `TradingFloor` package); best-effort throughout — ANY failure (throttle,
/// 404 on an unknown ticker, malformed body) yields `[]` and never throws.
///
/// US-listed equities ONLY. A CN/HK symbol (`CNSymbol.parse` succeeds) or any
/// symbol carrying an exchange-suffix dot (`.L`, `.T`, …) is rejected up front
/// with an empty result — StockTwits' cashtag namespace is US-centric and we
/// never want to silently mis-route a foreign ticker.
public struct StockTwitsClient: Sendable {
    public let session: URLSession
    public let limiter: HTTPRateLimiter

    private static let host = "api.stocktwits.com"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public init(session: URLSession = .shared,
                limiter: HTTPRateLimiter = HTTPRateLimiter(minInterval: 0.5))
    {
        self.session = session
        self.limiter = limiter
    }

    /// True when `raw` is a bare US ticker (not CN/HK, no exchange-suffix dot).
    /// Mirrors the `isUSSymbol` gate used by the US-only EDGAR / FINRA tools.
    public static func isUSSymbol(_ raw: String) -> Bool {
        CNSymbol.parse(raw) == nil && !raw.contains(".")
    }

    /// Recent messages for a US ticker, newest first (the order StockTwits
    /// returns). Returns `[]` (never throws) for non-US symbols and on any
    /// failure. `limit` caps how many of the returned messages we keep.
    public func messages(symbol: String, limit: Int = 30) async -> [StockTwitsMessage] {
        let raw = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, Self.isUSSymbol(raw) else { return [] }

        // StockTwits cashtags are uppercase; class-share dots can't reach here
        // (gated above), so a plain uppercase ticker is the right query form.
        let ticker = raw.uppercased()
        guard let url = URL(
            string: "https://\(Self.host)/api/2/streams/symbol/\(ticker).json")
        else { return [] }

        await limiter.acquire(host: Self.host)
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let payload = try? Self.decoder.decode(Stream.self, from: data)
        else { return [] }

        return payload.messages.prefix(max(limit, 0)).map(Self.map)
    }

    // MARK: - Wire model → public model

    private static func map(_ raw: Stream.Message) -> StockTwitsMessage {
        let sentiment: StockTwitsSentiment? = {
            switch raw.entities?.sentiment?.basic?.lowercased() {
            case "bullish": return .bullish
            case "bearish": return .bearish
            default:        return nil
            }
        }()
        let user = raw.user
        let author = StockTwitsAuthor(
            username: user?.username ?? "",
            name: user?.name ?? user?.username ?? "",
            avatarURL: user?.avatarURL.flatMap(URL.init(string:)),
            followers: user?.followers ?? 0,
            likeCount: user?.likeCount ?? 0)
        return StockTwitsMessage(
            id: raw.id,
            body: raw.body ?? "",
            createdAt: raw.createdAt ?? .distantPast,
            sentiment: sentiment,
            author: author,
            symbols: (raw.symbols ?? []).compactMap(\.symbol))
    }

    /// ISO8601 Zulu (`2026-06-15T08:18:54Z`) → `Date`.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Wire model (private; mirrors the documented JSON shape)

    private struct Stream: Decodable {
        let messages: [Message]

        struct Message: Decodable {
            let id: Int
            let body: String?
            let createdAt: Date?
            let entities: Entities?
            let user: User?
            let symbols: [Symbol]?

            enum CodingKeys: String, CodingKey {
                case id, body, entities, user, symbols
                case createdAt = "created_at"
            }
        }

        struct Entities: Decodable {
            let sentiment: Sentiment?
        }

        struct Sentiment: Decodable {
            // Upstream sends `{"basic": "Bullish"}` OR `null` for the whole
            // `sentiment` object — the optional chain above absorbs both.
            let basic: String?
        }

        struct User: Decodable {
            let username: String?
            let name: String?
            let avatarURL: String?
            let followers: Int?
            let likeCount: Int?

            enum CodingKeys: String, CodingKey {
                case username, name, followers
                case avatarURL = "avatar_url"
                case likeCount = "like_count"
            }
        }

        struct Symbol: Decodable {
            let symbol: String?
        }
    }
}
