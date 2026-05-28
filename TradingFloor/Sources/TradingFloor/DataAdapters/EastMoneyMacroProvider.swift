import Foundation

/// Fetches a Chinese macro backdrop from EastMoney's open datacenter
/// endpoints — no key required, Foundation-only so it builds on Linux
/// server AND in the macOS app. Mirrors `FredMacroProvider`'s shape so
/// the chain stays symmetric: each macro decorator owns one market and
/// fills `snapshot.macro` only for symbols that belong to it.
///
/// Reads CPI / PPI / PMI (制造业 + 非制造业) / M2 / RMB Loans monthly
/// releases — the headline series most analysts cite when framing
/// China's macro stance. LPR + 10Y CN bond yield were on the original
/// plan but their EastMoney reportNames keep moving; defer until we
/// commit to a stable secondary source.
public struct EastMoneyMacroClient: Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Render e.g. "CPI YoY +1.2%; PPI YoY -2.8%; PMI 制造业 50.3; PMI 服务业 49.4; M2 YoY +8.6%".
    public func macroSummary() async -> String {
        async let cpi  = fetchLatest(reportName: "RPT_ECONOMY_CPI",
                                      field: "NATIONAL_SAME")
        async let ppi  = fetchLatest(reportName: "RPT_ECONOMY_PPI",
                                      field: "BASE_SAME")
        async let pmiManuf = fetchLatest(reportName: "RPT_ECONOMY_PMI",
                                         field: "MAKE_INDEX")
        async let pmiServ  = fetchLatest(reportName: "RPT_ECONOMY_PMI",
                                         field: "NMAKE_INDEX")
        async let m2   = fetchLatest(reportName: "RPT_ECONOMY_CURRENCY_SUPPLY",
                                      field: "BASIC_CURRENCY_SAME")
        async let loans = fetchLatest(reportName: "RPT_ECONOMY_RMB_LOAN",
                                       field: "LOAN_ACCUMULATE_SAME")

        var parts: [String] = []
        if let v = await cpi  { parts.append("CPI YoY \(percent(v))") }
        if let v = await ppi  { parts.append("PPI YoY \(percent(v))") }
        if let v = await pmiManuf { parts.append("PMI 制造业 \(String(format: "%.1f", v))") }
        if let v = await pmiServ  { parts.append("PMI 服务业 \(String(format: "%.1f", v))") }
        if let v = await m2   { parts.append("M2 YoY \(percent(v))") }
        if let v = await loans {
            // RMB loans monthly growth is a noisy series — round to one decimal,
            // keep sign-prefixed since negative months happen and the LLM
            // needs to see the direction.
            parts.append("人民币贷款累计 YoY \(percent(v))")
        }
        return parts.joined(separator: "; ")
    }

    /// One generic call against EastMoney's `datacenter-web` endpoint.
    /// Best-effort: any failure (network, schema drift, "-" cell) drops
    /// that line from the summary rather than failing the snapshot.
    private func fetchLatest(reportName: String, field: String) async -> Double? {
        var c = URLComponents(string: "https://datacenter-web.eastmoney.com/api/data/v1/get")!
        c.queryItems = [
            .init(name: "reportName", value: reportName),
            .init(name: "columns", value: "REPORT_DATE,\(field)"),
            .init(name: "pageNumber", value: "1"),
            .init(name: "pageSize", value: "1"),
            .init(name: "sortColumns", value: "REPORT_DATE"),
            .init(name: "sortTypes", value: "-1"),
        ]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://data.eastmoney.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let rows = result["data"] as? [[String: Any]],
              let row = rows.first,
              let raw = row[field]
        else { return nil }
        if let d = raw as? Double { return d }
        if let i = raw as? Int    { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    private func percent(_ value: Double) -> String {
        String(format: "%+.1f%%", value)
    }
}

/// Wraps any base provider and fills the snapshot's `macro` field from
/// EastMoney **only for Chinese / Hong Kong tickers**. Non-CN symbols
/// pass through untouched so a sibling `FredMacroProvider` later in the
/// chain can fill the US/international macro slot. Per-day cache: macro
/// values don't change tick-to-tick, fetch once per trading day.
public actor EastMoneyMacroProvider: MarketDataProvider {
    private let base: any MarketDataProvider
    private let client: EastMoneyMacroClient
    private var cachedMacro: (day: String, summary: String)?

    public init(base: any MarketDataProvider,
                client: EastMoneyMacroClient = EastMoneyMacroClient())
    {
        self.base = base
        self.client = client
    }

    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        var snapshot = try await base.snapshot(symbol: symbol, asOf: asOf)
        guard CNSymbol.isCN(symbol) else { return snapshot }
        let summary = await macro(asOf: asOf)
        if !summary.isEmpty {
            // Don't clobber if the base already filled it (some future
            // decorator might). Append rather than replace.
            snapshot.macro = snapshot.macro.isEmpty
                ? summary
                : snapshot.macro + "\n" + summary
        }
        return snapshot
    }

    private func macro(asOf: Date) async -> String {
        let day = TradingDay.key(asOf)
        if let cached = cachedMacro, cached.day == day { return cached.summary }
        let summary = await client.macroSummary()
        if !summary.isEmpty { cachedMacro = (day, summary) }
        return summary
    }
}
