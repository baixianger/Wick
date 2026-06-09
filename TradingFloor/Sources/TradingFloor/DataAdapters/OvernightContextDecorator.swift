import Foundation

/// Adds an "隔夜外盘" (overnight external markets) line to the snapshot's
/// `macro` field for Chinese A-share / Hong Kong tickers — the prior-session
/// US close plus the instruments A-share traders actually watch before the
/// 09:30 open:
///
///   • 标普500 / 纳斯达克 — broad US risk appetite overnight
///   • 金龙中国 (NASDAQ Golden Dragon, ^HXC) — how US-listed Chinese ADRs
///     traded while A-shares were closed; the closest overnight proxy for
///     CN-equity sentiment
///   • 富时中国A50 (XIN9.FGI) — the SGX-linked A50 index, the standard
///     lead indicator for the A-share open
///   • 离岸人民币 (USD/CNH) — FX pressure transmits straight into northbound
///     flows and the PBoC fix
///   • 美债10Y (^TNX) — the global discount rate; rendered with a basis-point
///     day change because percent-change on a yield is misleading
///
/// Gated on `CNSymbol.isCN` — US/intl tickers already live inside the US
/// session, so "overnight US" is meaningless for them and the slot stays
/// clean. Source: Yahoo Finance's public v8 chart endpoint via the shared
/// `YahooChartQuote` helper (no auth, Foundation HTTP, Linux-safe for
/// WickServer). Per-day cache: one 6-quote fetch covers every CN ticker
/// that day.
///
/// Best-effort across the basket: partial failures drop only the failed
/// leg rather than the whole line.
public actor OvernightContextDecorator: MarketDataProvider {
    private let base: any MarketDataProvider
    private let session: URLSession
    private var cached: (day: String, line: String)?

    public init(base: any MarketDataProvider,
                session: URLSession = .shared)
    {
        self.base = base
        self.session = session
    }

    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        var snap = try await base.snapshot(symbol: symbol, asOf: asOf)
        guard CNSymbol.isCN(snap.symbol) else { return snap }
        let line = await overnightLine(asOf: asOf)
        if !line.isEmpty {
            snap.macro = snap.macro.isEmpty ? line : snap.macro + "\n" + line
        }
        return snap
    }

    private func overnightLine(asOf: Date) async -> String {
        let day = TradingDay.key(asOf)
        if let c = cached, c.day == day { return c.line }

        async let spx = YahooChartQuote.fetch(symbol: "^GSPC", session: session)
        async let ndx = YahooChartQuote.fetch(symbol: "^IXIC", session: session)
        async let hxc = YahooChartQuote.fetch(symbol: "^HXC", session: session)
        async let a50 = YahooChartQuote.fetch(symbol: "XIN9.FGI", session: session)
        async let cnh = YahooChartQuote.fetch(symbol: "CNH=X", session: session)
        async let t10 = YahooChartQuote.fetch(symbol: "^TNX", session: session)
        let (a, b, c, d, e, f) = await (spx, ndx, hxc, a50, cnh, t10)

        var parts: [String] = []
        if let q = a { parts.append(format(label: "标普500", quote: q)) }
        if let q = b { parts.append(format(label: "纳斯达克", quote: q)) }
        if let q = c { parts.append(format(label: "金龙中国", quote: q)) }
        if let q = d { parts.append(format(label: "富时A50", quote: q)) }
        if let q = e { parts.append(format(label: "离岸人民币", quote: q, fractionDigits: 4)) }
        if let q = f { parts.append(formatYield(label: "美债10Y", quote: q)) }

        guard !parts.isEmpty else { return "" }
        let line = "隔夜外盘 " + parts.joined(separator: "; ")
        cached = (day, line)
        return line
    }

    // MARK: - Rendering

    /// `标普500 7,387 (-0.3%)` — indices get a thousands separator like the
    /// cross-asset line; FX keeps its conventional 4 decimals.
    private func format(label: String, quote: YahooChartQuote,
                        fractionDigits: Int = 2) -> String
    {
        let priceStr: String
        if quote.price >= 1000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_US")
            formatter.usesGroupingSeparator = true
            formatter.maximumFractionDigits = 0
            priceStr = formatter.string(from: NSNumber(value: quote.price)) ?? "\(quote.price)"
        } else {
            priceStr = String(format: "%.\(fractionDigits)f", quote.price)
        }
        return "\(label) \(priceStr) (\(String(format: "%+.1f%%", quote.dayChangePct)))"
    }

    /// `美债10Y 4.53% (-2.4bp)`. `^TNX` quotes the yield directly in percent;
    /// the day move is rendered in basis points because a percent-change on a
    /// yield ("-0.5%") reads as a price move and routinely misleads.
    private func formatYield(label: String, quote: YahooChartQuote) -> String {
        let bp = (quote.price - quote.previousClose) * 100
        return "\(label) \(String(format: "%.2f%%", quote.price)) (\(String(format: "%+.1fbp", bp)))"
    }
}
