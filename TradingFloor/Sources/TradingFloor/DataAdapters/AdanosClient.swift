import Foundation

/// Reddit aggregates only: one request per symbol/window, no paid raw-post endpoint.
/// Actor cache is shared by the UI and agent and scoped to this credential instance.
public actor AdanosClient {
    private let apiKey: String
    private let session: URLSession
    private var cache: [String: (Date, AdanosStock?)] = [:]
    private var pending: [String: Task<AdanosStock?, Error>] = [:]

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func stock(symbol: String, asOf: Date = .now) async throws -> AdanosStock? {
        let symbol = symbol.uppercased()
        guard symbol.range(of: "^[A-Z]{1,10}$", options: .regularExpression) != nil else {
            throw DataAPIError.unsupportedSymbol
        }
        let from = DataAPI.day(asOf.addingTimeInterval(-6 * 86_400))
        let to = DataAPI.day(asOf)
        let id = "\(symbol):\(from):\(to)"
        if let cached = cache[id], Date().timeIntervalSince(cached.0) < 300 { return cached.1 }
        if let task = pending[id] { return try await task.value }
        let task = Task { [apiKey, session] () throws -> AdanosStock? in
            var url = URLComponents(string: "https://api.adanos.org/reddit/stocks/v1/compare")!
            url.queryItems = [.init(name: "tickers", value: symbol),
                              .init(name: "from", value: from), .init(name: "to", value: to)]
            var request = URLRequest(url: url.url!)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            let data = try await DataAPI.fetch(request, session: session)
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
                throw DataAPIError.invalidResponse
            }
            return response.stocks.first { $0.ticker.uppercased() == symbol }
        }
        pending[id] = task
        defer { pending[id] = nil }
        let value = try await task.value
        if cache.count >= 100 { cache.removeAll() }
        cache[id] = (Date(), value)
        return value
    }

    private struct Response: Decodable { let stocks: [AdanosStock]; let period_days: Int }
}

public struct AdanosStock: Decodable, Sendable {
    public let ticker: String
    public let mentions: Int?
    public let buzz_score: Double?
    public let sentiment_score: Double?
    public let bullish_pct: Double?
    public let bearish_pct: Double?
}

public struct AdanosSentimentProvider: SocialSentimentProvider {
    public let sourceName = "Adanos / Reddit"
    public var requiresUserCredentials: Bool { true }
    public let client: AdanosClient
    public init(client: AdanosClient) { self.client = client }
    public func sentiment(symbol: String, asOf: Date) async throws -> SocialSentiment {
        let stock = try await client.stock(symbol: symbol, asOf: asOf)
        let start = DataAPI.day(asOf.addingTimeInterval(-6 * 86_400))
        let end = DataAPI.day(asOf)
        let summary: String
        if let stock {
            let score = stock.sentiment_score.map { String($0) } ?? "unavailable"
            let mentions = stock.mentions.map { String($0) } ?? "unavailable"
            summary = "UTC \(start) through \(end): Reddit mentions \(mentions), sentiment \(score) (-1…1). Aggregates, not a price forecast."
        } else { summary = "No qualifying Reddit data for UTC \(start) through \(end); not neutral sentiment." }
        return SocialSentiment(symbol: symbol, asOf: asOf, source: sourceName, summary: summary, posts: [])
    }
}
