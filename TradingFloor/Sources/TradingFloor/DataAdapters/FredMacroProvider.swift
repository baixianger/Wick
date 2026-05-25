import Foundation

/// Fetches a macro backdrop from FRED (St. Louis Fed) — free,
/// commercial-OK with attribution, Foundation-only so it builds on
/// Linux server AND in the macOS app. Reads a handful of headline
/// series and renders a one-line summary for the desk.
///
/// Public so both server tier (our key) and BYO tier (user's key)
/// can construct it.
public struct FredClient: Sendable {
    public let apiKey: String
    public let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Series we care about → label + optional `units` transform.
    private static let series: [(id: String, label: String, units: String, suffix: String)] = [
        ("FEDFUNDS", "Fed funds",     "lin", "%"),
        ("DGS10",    "10y",           "lin", "%"),
        ("T10Y2Y",   "10y-2y spread", "lin", "%"),
        ("UNRATE",   "unemployment",  "lin", "%"),
        ("CPIAUCSL", "CPI YoY",       "pc1", "%"),   // pc1 = % change from year ago
    ]

    /// Render e.g. "Fed funds 3.64%; 10y 4.20%; 10y-2y +0.30%; unemployment 4.10%; CPI YoY 2.80%".
    public func macroSummary() async -> String {
        let parts = await withTaskGroup(of: (Int, String?).self) { group in
            for (i, s) in Self.series.enumerated() {
                group.addTask { (i, await latest(s.id, units: s.units).map { "\(s.label) \($0)\(s.suffix)" }) }
            }
            var out: [(Int, String)] = []
            for await (i, text) in group { if let text { out.append((i, text)) } }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return parts.joined(separator: "; ")
    }

    private func latest(_ seriesID: String, units: String) async -> String? {
        var components = URLComponents(string: "https://api.stlouisfed.org/fred/series/observations")!
        components.queryItems = [
            .init(name: "series_id", value: seriesID),
            .init(name: "api_key", value: apiKey),
            .init(name: "file_type", value: "json"),
            .init(name: "sort_order", value: "desc"),
            .init(name: "limit", value: "1"),
            .init(name: "units", value: units),
        ]
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let decoded = try? JSONDecoder().decode(Reply.self, from: data),
              let value = decoded.observations.first?.value, value != "." else { return nil }
        return Double(value).map { String(format: "%.2f", $0) } ?? value
    }

    private struct Reply: Decodable {
        struct Observation: Decodable { let value: String }
        let observations: [Observation]
    }
}

/// Wraps any base provider and fills the snapshot's `macro` field from
/// FRED. Macro is per-day (not per-ticker), so it's fetched once and
/// cached for the process lifetime here; the report cache then makes
/// it free thereafter.
public actor FredMacroProvider: MarketDataProvider {
    private let base: any MarketDataProvider
    private let fred: FredClient
    private var cachedMacro: (day: String, summary: String)?

    public init(base: any MarketDataProvider, fred: FredClient) {
        self.base = base
        self.fred = fred
    }

    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        var snapshot = try await base.snapshot(symbol: symbol, asOf: asOf)
        snapshot.macro = await macro(asOf: asOf)
        return snapshot
    }

    private func macro(asOf: Date) async -> String {
        let day = TradingDay.key(asOf)
        if let cached = cachedMacro, cached.day == day { return cached.summary }
        let summary = await fred.macroSummary()
        if !summary.isEmpty { cachedMacro = (day, summary) }
        return summary
    }
}
