import Foundation
import Observation
import TradingFloor

/// On-demand real news with a five-minute cache. Empty or unavailable
/// upstream data stays empty; synthetic headlines are never substituted.
@Observable
@MainActor
final class NewsStore {

    @ObservationIgnored
    private let provider = StockNewsProvider()

    /// symbol → fetched 东方财富 / Yahoo headlines (possibly empty after a miss).
    private var cache: [String: [NewsItem]] = [:]
    /// Symbols with a fetch in progress — guards against duplicate requests
    /// while a row is repeatedly re-evaluated by SwiftUI.
    @ObservationIgnored
    private var inFlight: Set<String> = []

    @ObservationIgnored private var finnhub: FinnhubClient?
    @ObservationIgnored private var configuredKey = ""
    @ObservationIgnored private var generation = UUID()
    private var fetchedAt: [String: Date] = [:]

    init() {}

    func configure(finnhubKey: String) {
        guard configuredKey != finnhubKey else { return }
        configuredKey = finnhubKey
        finnhub = finnhubKey.isEmpty ? nil : FinnhubClient(apiKey: finnhubKey)
        generation = UUID()
        cache.removeAll(); fetchedAt.removeAll(); inFlight.removeAll()
    }


    /// Cached real news for `symbol`, or `nil` until it loads. For a symbol
    /// that isn't cached and isn't already being fetched, this triggers a
    /// background fetch as a side effect. An empty (but non-nil) array means
    /// "fetched, no headlines available".
    func items(for symbol: String) -> [NewsItem]? {
        if let cached = cache[symbol], let date = fetchedAt[symbol], Date().timeIntervalSince(date) < 300 { return cached }
        guard !inFlight.contains(symbol) else { return cache[symbol] }
        inFlight.insert(symbol)
        let revision = generation
        Task { [provider, finnhub] in
            var origin: NewsProvider = CNSymbol.parse(symbol) != nil ? .eastMoney : .yahoo
            var articles: [NewsArticle] = []
            if let finnhub, StockTwitsClient.isUSSymbol(symbol) {
                articles = (try? await finnhub.articles(symbol: symbol)) ?? []
                if !articles.isEmpty { origin = .finnhub }
            }
            if articles.isEmpty { articles = await provider.news(symbol: symbol) }
            guard self.generation == revision else { return }
            self.fetchedAt[symbol] = Date()
            self.inFlight.remove(symbol)
            self.cache[symbol] = articles.map { Self.map($0, asOf: Date(), provider: origin) }
        }
        return nil
    }

    func display(for symbol: String) -> [NewsItem] {
        items(for: symbol) ?? []
    }

    /// Map a fetched `NewsArticle` into the view's `NewsItem`, computing the
    /// age (minutes) from `published` relative to `asOf`. Articles without a
    /// timestamp keep an unknown age and sort after dated articles.
    private static func map(_ a: NewsArticle, asOf: Date, provider: NewsProvider) -> NewsItem {
        let ageMinutes: Int
        if let published = a.published {
            ageMinutes = max(0, Int(asOf.timeIntervalSince(published) / 60))
        } else {
            ageMinutes = -1
        }
        return NewsItem(
            source: a.publisher ?? "",
            headline: a.title,
            summary: a.summary ?? "",
            ageMinutes: ageMinutes,
            url: a.link.flatMap(URL.init(string:)),
            provider: provider)
    }

}
