import Foundation

/// Fetches recent company headlines from Finnhub to fill the snapshot's
/// `news` (which feeds the news + sentiment analysts). Foundation-only,
/// best-effort. Public so both server tier (our key) and BYO tier
/// (user's key) can construct it.
public struct FinnhubClient: Sendable {
    public let apiKey: String
    public let session: URLSession
    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func headlines(symbol: String,
                          asOf: Date,
                          limit: Int = 6) async -> [String]
    {
        let day = ISO8601DateFormatter(); day.formatOptions = [.withFullDate]
        let from = day.string(from: asOf.addingTimeInterval(-14 * 86_400))
        let to = day.string(from: asOf)

        var components = URLComponents(string: "https://finnhub.io/api/v1/company-news")!
        components.queryItems = [
            .init(name: "symbol", value: symbol),
            .init(name: "from", value: from),
            .init(name: "to", value: to),
            .init(name: "token", value: apiKey),
        ]
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items.prefix(limit).map { item in
            item.source.map { "\(item.headline) (\($0))" } ?? item.headline
        }
    }

    private struct Item: Decodable { let headline: String; let source: String? }
}

/// Decorator: fills `news` from Finnhub if the base left it empty.
public struct FinnhubNewsProvider: MarketDataProvider {
    public let base: any MarketDataProvider
    public let finnhub: FinnhubClient

    public init(base: any MarketDataProvider, finnhub: FinnhubClient) {
        self.base = base
        self.finnhub = finnhub
    }

    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        var snapshot = try await base.snapshot(symbol: symbol, asOf: asOf)
        if snapshot.news.isEmpty {
            snapshot.news = await finnhub.headlines(symbol: symbol, asOf: asOf)
        }
        return snapshot
    }
}
