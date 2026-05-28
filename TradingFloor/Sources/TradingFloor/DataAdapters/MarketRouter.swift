import Foundation

/// Dispatches per-snapshot between a Chinese-market provider (EastMoney) and a
/// fallback provider (FMP on server, or another router on the app side). Lives
/// in TradingFloor so both WickServer and the app share one routing rule for
/// `.SS` / `.SZ` / `.HK` tickers — there's no reasonable scenario where the
/// server should ask FMP for `600519.SS` and the app should ask EastMoney for
/// the same input; the canonical form is the deciding bit.
///
/// The router itself doesn't know anything about "international" tickers like
/// `RIO.L` or `7203.T` — those are app-only because they go through CandleKit
/// + Yahoo, which doesn't build on Linux. The app side composes:
///
///   `MarketRouter(cn: EastMoney, fallback: InternationalRouter(intl: Yahoo, us: FMP))`
///
/// The server side simply passes `MarketRouter(cn: EastMoney, fallback: FMP)`.
public struct MarketRouter: MarketDataProvider {
    public let cn: any MarketDataProvider
    public let fallback: any MarketDataProvider

    public init(cn: any MarketDataProvider, fallback: any MarketDataProvider) {
        self.cn = cn
        self.fallback = fallback
    }

    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        // `isCN` only accepts already-canonical input — `.SS / .SZ / .HK`
        // suffix present. LLM tool calls and user input frequently pass
        // bare digits (`600519`), prefix-style (`SH600519`), or hyphen
        // forms; route those through `CNSymbol.parse` first so they
        // reach the EastMoney provider instead of being silently
        // dropped to the US/Stub fallback.
        if let canonical = CNSymbol.parse(symbol) {
            return try await cn.snapshot(symbol: canonical, asOf: asOf)
        }
        return try await fallback.snapshot(symbol: symbol, asOf: asOf)
    }
}
