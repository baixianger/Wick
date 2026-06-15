import Foundation

/// Per-ticker data from Financial Modeling Prep (FMP). Foundation-only
/// (no CandleKit → builds on Linux server AND in the macOS app).
/// Fills price, technicals (via shared `Technicals`), and fundamentals.
/// Best-effort: a failed sub-fetch degrades that section rather than
/// failing the whole snapshot.
///
/// News headlines come from FMP's per-symbol stock-news endpoint and
/// feed the news + sentiment analysts (capped at the most recent few).
/// Best-effort like every other section: if the news fetch fails it
/// degrades to an empty list rather than failing the snapshot.
///
/// Public so both WickServer (server tier, uses our key) and the Wick
/// app (BYO tier, user's key) can construct it from a single source of
/// truth. Configure via [[wick-business-model]]'s two-tier split.
public struct FMPMarketDataProvider: MarketDataProvider {
    public let apiKey: String
    public let session: URLSession
    private let base = "https://financialmodelingprep.com/stable"

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        async let barsTask: [Bar] = get("historical-price-eod/full", symbol: symbol)
        async let profileTask: [Profile] = get("profile", symbol: symbol)
        async let incomeTask: [Income] = get("income-statement", symbol: symbol, extra: ["limit": "2"])
        async let newsTask: [String] = headlines(symbol: symbol)
        let bars = await barsTask, profiles = await profileTask, income = await incomeTask
        let news = await newsTask

        // FMP returns history newest-first; Technicals wants chronological.
        let chron = Array(bars.reversed())
        let closes = chron.map(\.close)
        let profile = profiles.first
        let last = closes.last ?? profile?.price ?? 0

        var fundamentals: [String: String] = [:]
        if let p = profile {
            if let i = p.industry { fundamentals["Industry"] = i }
            if let c = p.marketCap { fundamentals["Market cap"] = bigNumber(c) }
            if let b = p.beta { fundamentals["Beta"] = String(format: "%.2f", b) }
        }
        if let cur = income.first {
            if let rev = cur.revenue {
                fundamentals["Revenue (FY\(cur.fiscalYear ?? ""))"] = bigNumber(rev)
                if let gp = cur.grossProfit, rev != 0 { fundamentals["Gross margin"] = percent(gp / rev) }
                if let ni = cur.netIncome, rev != 0 { fundamentals["Net margin"] = percent(ni / rev) }
                if let prev = income.dropFirst().first?.revenue, prev != 0 {
                    fundamentals["Rev YoY"] = percent((rev - prev) / prev)
                }
            }
            if let eps = cur.eps, eps != 0 { fundamentals["EPS"] = String(format: "%.2f", eps) }
        }

        return MarketSnapshot(
            symbol: symbol,
            asOf: asOf,
            lastPrice: last == 0 ? nil : last,
            priceSummary: Technicals.priceSummary(closes: closes,
                                                  highs: chron.map(\.high),
                                                  lows: chron.map(\.low),
                                                  last: last),
            technicals: Technicals.technicalsSummary(closes: closes, last: last),
            fundamentals: fundamentals,
            news: news
        )
    }

    // MARK: - Fetch (best-effort: [] on any failure)

    /// Recent per-symbol headlines via FMP stable `search-stock-news`,
    /// which takes `symbols` (plural) rather than the `symbol` the other
    /// endpoints use, so it gets its own fetch instead of the generic
    /// `get` helper. Formatted "Headline (Site)" for the news-analyst.
    ///
    /// NOTE: FMP's News dataset is a paid add-on. Verified 2026-06-15
    /// against the live API: `search-stock-news` returns `[]` on the
    /// current plan (the `news/*-latest` endpoints hard-error
    /// "Restricted Endpoint"). This stays best-effort — news degrades to
    /// empty until the FMP plan includes News, then it lights up with no
    /// code change. Response fields per docs: title, site, publishedDate,
    /// publisher, text, url, image, symbol.
    private func headlines(symbol: String, limit: Int = 6) async -> [String] {
        var components = URLComponents(string: "\(base)/search-stock-news")!
        components.queryItems = [
            .init(name: "symbols", value: symbol),
            .init(name: "limit", value: String(limit)),
            .init(name: "apikey", value: apiKey),
        ]
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let items = try? JSONDecoder().decode([NewsItem].self, from: data) else { return [] }
        return items.prefix(limit).map { item in
            item.site.map { "\(item.title) (\($0))" } ?? item.title
        }
    }

    private func get<T: Decodable>(_ path: String, symbol: String, extra: [String: String] = [:]) async -> [T] {
        var components = URLComponents(string: "\(base)/\(path)")!
        components.queryItems = [.init(name: "symbol", value: symbol), .init(name: "apikey", value: apiKey)]
            + extra.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let decoded = try? JSONDecoder().decode([T].self, from: data) else { return [] }
        return decoded
    }

    // MARK: - Wire types (only the fields we use)

    private struct Bar: Decodable { let high: Double; let low: Double; let close: Double }
    private struct Profile: Decodable {
        let price: Double?; let marketCap: Double?; let beta: Double?; let industry: String?
    }
    private struct Income: Decodable {
        let fiscalYear: String?; let revenue: Double?; let grossProfit: Double?
        let netIncome: Double?; let eps: Double?
    }
    private struct NewsItem: Decodable { let title: String; let site: String? }

    // MARK: - Formatting

    private func percent(_ ratio: Double) -> String { String(format: "%+.1f%%", ratio * 100) }
    private func bigNumber(_ value: Double) -> String {
        switch abs(value) {
        case 1e12...: return String(format: "$%.2fT", value / 1e12)
        case 1e9...:  return String(format: "$%.1fB", value / 1e9)
        case 1e6...:  return String(format: "$%.0fM", value / 1e6)
        default:      return String(format: "$%.0f", value)
        }
    }
}
