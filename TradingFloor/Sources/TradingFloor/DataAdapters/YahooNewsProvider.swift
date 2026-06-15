import Foundation

/// Decorator: fills `news` from Yahoo Finance's keyless search feed if the base
/// left it empty. Covers ALL non-CN/HK symbols (US + international), so it sits
/// AFTER `FinnhubNewsProvider` in the chain — for US tickers Finnhub fills
/// first and this only runs if news is still empty; for international tickers
/// Yahoo is the sole news source.
///
/// Reuses `StockNewsProvider.yahoo` (the same keyless `v1/finance/search`
/// feed the News tab uses) rather than re-implementing the fetch. CN/HK
/// symbols (`CNSymbol.parse` succeeds) pass straight through untouched — their
/// news comes from the EastMoney decorators upstream. Foundation-only,
/// best-effort: any failure leaves `news` as the base produced it.
public struct YahooNewsProvider: MarketDataProvider {
    public let base: any MarketDataProvider
    public let stockNews: StockNewsProvider

    public init(base: any MarketDataProvider,
                stockNews: StockNewsProvider = StockNewsProvider())
    {
        self.base = base
        self.stockNews = stockNews
    }

    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        var snapshot = try await base.snapshot(symbol: symbol, asOf: asOf)
        guard snapshot.news.isEmpty, CNSymbol.parse(symbol) == nil else {
            return snapshot
        }
        // Reuse the News-tab Yahoo fetch, then flatten `[NewsArticle]` →
        // `[String]` in the same `"Title (Publisher)"` shape Finnhub produces.
        let articles = await stockNews.yahoo(symbol: symbol, limit: 6)
        let headlines = articles.prefix(6).map { article -> String in
            if let publisher = article.publisher, !publisher.isEmpty {
                return "\(article.title) (\(publisher))"
            }
            return article.title
        }
        if !headlines.isEmpty {
            snapshot.news = headlines
        }
        return snapshot
    }
}
