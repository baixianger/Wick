import Foundation
import Observation
import TradingFloor

/// On-demand cache of REAL per-ticker news — the live replacement for
/// `NewsFixtures` in the Overview / News tabs. The localized counterpart of
/// `LiveDataStore` (prices) and `CNNameStore` (简称): same `@Observable`
/// `@MainActor` synchronous-read / background-fetch / cache-then-rerender
/// pattern.
///
/// `items(for:)` is synchronous: it returns the cached headlines if present,
/// otherwise (for a symbol not already in flight) kicks a background fetch and
/// returns `nil`. The view shows `NewsFixtures` while `nil`, and re-renders
/// with the real news once the fetch lands — so the tab is never blank.
///
/// Routing matches `LiveDataStore`: CN A-share / HK symbols (`CNSymbol.parse`)
/// pull from 东方财富 (EastMoney) 资讯; everything else (US / international)
/// pulls from Yahoo Finance. See `StockNewsProvider`. Best-effort: a failed or
/// empty fetch caches an empty array (so we don't hammer a dead symbol) and the
/// caller keeps the fixture fallback.
@Observable
@MainActor
final class NewsStore {

    @ObservationIgnored
    private let provider = StockNewsProvider()

    /// symbol → fetched headlines (possibly empty after a miss).
    private var cache: [String: [NewsItem]] = [:]
    /// Symbols with a fetch in progress — guards against duplicate requests
    /// while a row is repeatedly re-evaluated by SwiftUI.
    @ObservationIgnored
    private var inFlight: Set<String> = []

    init() {}

    /// Cached real news for `symbol`, or `nil` until it loads. For a symbol
    /// that isn't cached and isn't already being fetched, this triggers a
    /// background fetch as a side effect. An empty (but non-nil) array means
    /// "fetched, nothing found" — the caller still falls back to fixtures.
    func items(for symbol: String) -> [NewsItem]? {
        if let cached = cache[symbol] { return cached }
        guard !inFlight.contains(symbol) else { return nil }
        inFlight.insert(symbol)
        Task { [provider] in
            let articles = await provider.news(symbol: symbol)
            self.inFlight.remove(symbol)
            self.cache[symbol] = articles.map { Self.map($0, asOf: Date()) }
        }
        return nil
    }

    /// The list to render: real fetched news when available and non-empty,
    /// otherwise the `NewsFixtures` fallback (loading / empty / last-resort) so
    /// the tab is never blank.
    func display(for symbol: String) -> [NewsItem] {
        if let real = items(for: symbol), !real.isEmpty { return real }
        return NewsFixtures.items(for: symbol)
    }

    /// Map a fetched `NewsArticle` into the view's `NewsItem`, computing the
    /// age (minutes) from `published` relative to `asOf`. Articles without a
    /// timestamp sort to "0m" (treated as just-now) rather than dropping.
    private static func map(_ a: NewsArticle, asOf: Date) -> NewsItem {
        let ageMinutes: Int
        if let published = a.published {
            ageMinutes = max(0, Int(asOf.timeIntervalSince(published) / 60))
        } else {
            ageMinutes = 0
        }
        return NewsItem(
            source: a.publisher ?? "",
            headline: a.title,
            summary: a.summary ?? "",
            ageMinutes: ageMinutes,
            url: a.link.flatMap(URL.init(string:)))
    }
}
