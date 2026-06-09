import Foundation

/// Adds a "global climate" line to the snapshot's `macro` field —
/// WTI crude, gold, BTC, US dollar index, and VIX — so the LLM can
/// frame an individual stock against the broader risk regime and
/// related-instrument moves. Source: Yahoo Finance's public v8 chart
/// endpoint (no auth, Foundation HTTP, the same endpoint CandleKit's
/// `YahooFinanceAdapter` uses but called directly here so the
/// decorator stays Linux-compatible for WickServer).
///
/// Per-day cache for the whole basket: every CN ticker + every US
/// ticker shares the same 5-quote payload. Fetched once per process
/// per trading day; the report cache amortises the rest.
///
/// Best-effort across the basket: if Yahoo's API returns partial data
/// (one symbol fails, others succeed), we surface what worked rather
/// than dropping the whole section.
public actor CrossAssetContextDecorator: MarketDataProvider {
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
        let line = await crossAssetLine(asOf: asOf)
        if !line.isEmpty {
            snap.macro = snap.macro.isEmpty ? line : snap.macro + "\n" + line
        }
        return snap
    }

    private func crossAssetLine(asOf: Date) async -> String {
        let day = TradingDay.key(asOf)
        if let c = cached, c.day == day { return c.line }

        // Fetch each leg in parallel — Yahoo's chart endpoint is
        // per-symbol so we burn 5 concurrent requests once per day.
        async let wti  = YahooChartQuote.fetch(symbol: "CL=F", session: session)
        async let gold = YahooChartQuote.fetch(symbol: "GC=F", session: session)
        async let btc  = YahooChartQuote.fetch(symbol: "BTC-USD", session: session)
        async let dxy  = YahooChartQuote.fetch(symbol: "DX-Y.NYB", session: session)
        async let vix  = YahooChartQuote.fetch(symbol: "^VIX", session: session)
        let (a, b, c, d, e) = await (wti, gold, btc, dxy, vix)

        var parts: [String] = []
        if let q = a { parts.append(format(label: "WTI",  quote: q, currency: "$")) }
        if let q = b { parts.append(format(label: "Gold", quote: q, currency: "$")) }
        if let q = c { parts.append(format(label: "BTC",  quote: q, currency: "$")) }
        if let q = d { parts.append(format(label: "DXY",  quote: q, currency: "")) }
        if let q = e { parts.append(format(label: "VIX",  quote: q, currency: "")) }

        guard !parts.isEmpty else { return "" }
        let line = "跨资产 " + parts.joined(separator: "; ")
        cached = (day, line)
        return line
    }

    // MARK: - Rendering

    /// Formats `Gold $4527.30 (-0.1%)`. Big-currency symbols (BTC, oil,
    /// gold) get a thousands separator, small ones don't.
    private func format(label: String, quote: YahooChartQuote, currency: String) -> String {
        let priceStr: String
        if quote.price >= 1000 {
            // Force en_US so the thousands separator is `,` not `.`
            // (European locale would render $73.749 which reads as "73
            // point seven four nine dollars" — wrong for BTC / Gold).
            // `en_US_POSIX` strips grouping; `en_US` keeps it.
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_US")
            formatter.usesGroupingSeparator = true
            formatter.maximumFractionDigits = 0
            priceStr = formatter.string(from: NSNumber(value: quote.price)) ?? "\(quote.price)"
        } else {
            priceStr = String(format: "%.2f", quote.price)
        }
        return "\(label) \(currency)\(priceStr) (\(String(format: "%+.1f%%", quote.dayChangePct)))"
    }
}
