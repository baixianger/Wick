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

    /// symbol → fetched 东方财富 / Yahoo headlines (possibly empty after a miss).
    private var cache: [String: [NewsItem]] = [:]
    /// Symbols with a fetch in progress — guards against duplicate requests
    /// while a row is repeatedly re-evaluated by SwiftUI.
    @ObservationIgnored
    private var inFlight: Set<String> = []

    /// symbol → fetched 雪球 NEWS headlines (#54). Kept SEPARATE from `cache` so
    /// the BYO 雪球 feed (only present when the user is logged into 雪球) merges in
    /// without entangling the always-on 东方财富 / Yahoo cache. Empty (non-nil) ⇒
    /// "fetched, 雪球 had nothing / not logged in" — the tab then shows the
    /// 东方财富 items alone (no regression).
    private var xueqiuCache: [String: [NewsItem]] = [:]
    @ObservationIgnored
    private var xueqiuInFlight: Set<String> = []

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
            let origin: NewsProvider = CNSymbol.parse(symbol) != nil ? .eastMoney : .yahoo
            self.cache[symbol] = articles.map { Self.map($0, asOf: Date(), provider: origin) }
        }
        return nil
    }

    /// The list to render: real fetched news when available and non-empty,
    /// otherwise the `NewsFixtures` fallback (loading / empty / last-resort) so
    /// the tab is never blank. The 雪球 BYO feed (#54) is MERGED in (newest-first,
    /// de-duplicated) when present.
    ///
    /// `session` is the app-scoped `BrowserSessionManager` (typed `AnyObject?`,
    /// nil below macOS 26). When 雪球 is logged in for a CN/HK ticker, this
    /// triggers a one-shot background 雪球-news fetch (same BYO contract — only on
    /// demand, never auto-polled) and merges its items in once they land. When
    /// 雪球 isn't logged in (or the symbol isn't CN/HK), the list is the 东方财富 /
    /// Yahoo feed exactly as before — no regression.
    func display(for symbol: String, session: AnyObject? = nil) -> [NewsItem] {
        triggerXueqiuFetchIfReady(symbol: symbol, session: session)
        let base = items(for: symbol)
        let xueqiu = xueqiuCache[symbol]

        // Merge 东方财富 + 雪球 when at least one real feed has content; otherwise
        // fall back to fixtures so the tab is never blank.
        var merged: [NewsItem] = []
        if let base, !base.isEmpty { merged += base }
        if let xueqiu, !xueqiu.isEmpty { merged += xueqiu }
        guard !merged.isEmpty else { return NewsFixtures.items(for: symbol) }

        // De-dup by URL (the two feeds republish the same 财联社/证券时报 wires) then
        // sort newest-first so a fresh 雪球 item and a fresh 东方财富 item interleave
        // by recency rather than clumping by source.
        var seen = Set<String>()
        let deduped = merged.filter { item in
            let key = item.url?.absoluteString ?? item.headline
            return seen.insert(key).inserted
        }
        return deduped.sorted { $0.ageMinutes < $1.ageMinutes }
    }

    /// Kick a one-shot 雪球-news fetch for `symbol` IFF the 雪球 session is already
    /// logged in (BYO contract — never prompts, never auto-polls; the fetch runs
    /// only because the user opened the News tab and a valid session exists).
    /// No-op below macOS 26, for non-CN/HK symbols, when already cached, or when
    /// a fetch is in flight.
    private func triggerXueqiuFetchIfReady(symbol: String, session: AnyObject?) {
        guard CNSymbol.parse(symbol) != nil else { return }      // CN/HK only
        guard xueqiuCache[symbol] == nil, !xueqiuInFlight.contains(symbol) else { return }
        guard #available(macOS 26.0, *),
              let manager = session as? BrowserSessionManager,
              manager.status.canScrape                            // logged in only
        else { return }
        xueqiuInFlight.insert(symbol)
        Task {
            let items = await manager.news(for: symbol)
            self.xueqiuInFlight.remove(symbol)
            self.xueqiuCache[symbol] = items.map { Self.map($0, asOf: Date()) }
        }
    }

    /// Map a fetched `NewsArticle` into the view's `NewsItem`, computing the
    /// age (minutes) from `published` relative to `asOf`. Articles without a
    /// timestamp sort to "0m" (treated as just-now) rather than dropping.
    private static func map(_ a: NewsArticle, asOf: Date, provider: NewsProvider) -> NewsItem {
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
            url: a.link.flatMap(URL.init(string:)),
            provider: provider)
    }

    /// Map a 雪球 news item (#54) into the view's `NewsItem`, badged 雪球.
    private static func map(_ n: XueqiuNewsItem, asOf: Date) -> NewsItem {
        let ageMinutes: Int
        if let when = n.createdAt {
            ageMinutes = max(0, Int(asOf.timeIntervalSince(when) / 60))
        } else {
            ageMinutes = 0
        }
        return NewsItem(
            source: n.source,
            headline: n.title,
            summary: n.summary ?? "",
            ageMinutes: ageMinutes,
            url: n.url,
            provider: .xueqiu)
    }
}
