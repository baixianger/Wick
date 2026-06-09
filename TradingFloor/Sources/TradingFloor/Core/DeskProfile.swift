import Foundation

/// The natural language the desk reasons and reports in. The JSON envelope
/// tokens (`lean`, `rating` enums) stay English regardless — only headlines,
/// markdown bodies, and prompt instructions switch — so the parsers in
/// `Agents.swift` keep working unchanged. See `Prompts` for the locale split.
public enum DeskLocale: String, Sendable, Codable {
    case english
    case chinese
}

/// Which desk a given ticker routes to. The desk graph is identical for every
/// ticker (analysts → bull/bear debate → trader → risk); only the prompt
/// language, report language, and analyst roster differ by market. We do NOT
/// fork the engine — `TradingFloor.analyze` picks a profile per-ticker (the
/// same way the data layer already auto-routes by symbol) and threads it
/// through `AgentContext`.
///
/// Routing is purely symbol-shaped, mirroring `MarketRouter`:
///   • `CNSymbol.parse(ticker) != nil` → Chinese desk; else English desk.
///   • Within the Chinese desk, `CNSymbol.market` distinguishes A-share vs HK.
///     HK is a sub-variant of the Chinese desk (Chinese prompts/output), NOT
///     the US desk — it just drops the `capital` analyst (no main-force
///     fund-flow disclosure) and gets HK-specific microstructure notes.
public struct DeskProfile: Sendable, Equatable {
    public let locale: DeskLocale
    /// `nil` for the English desk; the concrete CN market for the Chinese desk.
    /// Lets prompts inject A-share vs HK microstructure notes (T+1, 涨跌停,
    /// 南向资金, …) without a second enum.
    public let market: CNSymbol.Market?
    /// The roster eligible to run for this desk. `TradingFloor.analyze`
    /// intersects this with `config.analysts`, so a US run never spawns the
    /// CN-only `policy` / `capital` analysts even though the default config
    /// enables every `AnalystKind`.
    public let analysts: [AnalystKind]

    public init(locale: DeskLocale, market: CNSymbol.Market?, analysts: [AnalystKind]) {
        self.locale = locale
        self.market = market
        self.analysts = analysts
    }

    /// The English desk: US / international tickers, English prompts + output,
    /// the original four-analyst roster.
    public static let english = DeskProfile(
        locale: .english,
        market: nil,
        analysts: [.fundamental, .technical, .sentiment, .news]
    )

    /// Pick the desk for a ticker. Canonicalises through `CNSymbol.parse` so
    /// every accepted CN shape (`SH600519`, `600519`, `0700.HK`, …) routes the
    /// same as its canonical form would.
    public static func forTicker(_ ticker: String) -> DeskProfile {
        guard let canonical = CNSymbol.parse(ticker),
              let market = CNSymbol.market(canonical)
        else { return .english }

        switch market {
        case .shanghai, .shenzhen:
            // Full A-share roster: the four shared analysts plus 政策面 + 资金面.
            return DeskProfile(
                locale: .chinese, market: market,
                analysts: [.fundamental, .technical, .sentiment, .news, .policy, .capital]
            )
        case .hongKong:
            // HK: Chinese desk, but no 资金面 — EastMoney exposes no
            // main-force fund-flow for market 116.
            return DeskProfile(
                locale: .chinese, market: market,
                analysts: [.fundamental, .technical, .sentiment, .news, .policy]
            )
        }
    }
}
