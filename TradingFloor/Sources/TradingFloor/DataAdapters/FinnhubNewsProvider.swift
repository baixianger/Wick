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
        guard let articles = try? await articles(symbol: symbol, asOf: asOf, limit: limit) else { return [] }
        return articles.map { "\($0.title) (\($0.publisher ?? "Finnhub"))" }
    }

    public func articles(symbol: String, asOf: Date = .now, limit: Int = 20) async throws -> [NewsArticle] {
        guard StockTwitsClient.isUSSymbol(symbol) else { throw DataAPIError.unsupportedSymbol }
        var components = URLComponents(string: "https://finnhub.io/api/v1/company-news")!
        let from = asOf.addingTimeInterval(-14 * 86_400)
        components.queryItems = [
            .init(name: "symbol", value: symbol.uppercased()),
            .init(name: "from", value: DataAPI.day(from)),
            .init(name: "to", value: DataAPI.day(asOf)),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(apiKey, forHTTPHeaderField: "X-Finnhub-Token")
        let data = try await DataAPI.fetch(request, session: session)
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else {
            throw DataAPIError.invalidResponse
        }
        var seen = Set<String>()
        return items.filter {
            !$0.headline.isEmpty && $0.datetime <= asOf.timeIntervalSince1970
                && $0.datetime >= from.timeIntervalSince1970
                && seen.insert($0.url ?? $0.headline).inserted
        }.sorted { $0.datetime > $1.datetime }.prefix(max(0, limit)).map {
            NewsArticle(title: $0.headline, summary: $0.summary, publisher: $0.source,
                        link: $0.url, published: Date(timeIntervalSince1970: $0.datetime))
        }
    }

    private struct Item: Decodable {
        let headline: String
        let source: String?
        let summary: String?
        let url: String?
        let datetime: Double
    }

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
