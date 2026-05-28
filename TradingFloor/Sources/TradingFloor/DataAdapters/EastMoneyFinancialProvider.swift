import Foundation

/// Decorator that augments a CN (A-share / Hong Kong) snapshot's
/// `fundamentals` with the latest quarter's income-statement digest pulled
/// from EastMoney's open `datacenter` tables. Non-CN symbols pass through
/// untouched. Foundation-only.
///
/// Two endpoints because EastMoney maintains different schemas for the two
/// markets:
///   • A-share:  `RPT_LICO_FN_CPD`           (营业总收入 / 净利润 / YoY / ROE / 毛利率 / EPS / 经营现金流)
///   • HK:       `RPT_HKF10_FN_MAININDICATOR` (Operate Income / Holder Profit / YoY / ROE / margins /
///                                              Debt-Asset Ratio / Operating Cashflow)
///
/// Both are no-key. Failures degrade the whole financial section — the
/// `EastMoneyMarketDataProvider` already supplied `市值 / PE / PB` so the
/// snapshot is never empty.
public struct EastMoneyFinancialProvider: MarketDataProvider {
    public let base: any MarketDataProvider
    public let session: URLSession
    public let limiter: HTTPRateLimiter

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public init(base: any MarketDataProvider,
                session: URLSession = .shared,
                limiter: HTTPRateLimiter = HTTPRateLimiter(minInterval: 0.2))
    {
        self.base = base
        self.session = session
        self.limiter = limiter
    }

    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        var snap = try await base.snapshot(symbol: symbol, asOf: asOf)
        guard let market = CNSymbol.market(symbol) else { return snap }

        let code = symbol.split(separator: ".").first.map(String.init) ?? ""
        guard !code.isEmpty else { return snap }

        switch market {
        case .shanghai, .shenzhen:
            if let row = await fetchAShareLatest(code: code) {
                merge(row.toFundamentals(), into: &snap.fundamentals)
            }
        case .hongKong:
            // EastMoney's F10 HK tables key on the 5-digit `SECUCODE`
            // (`00700.HK`), not the canonical 4-digit form.
            guard let secucode = CNSymbol.eastMoneyF10HKSecucode(symbol) else { return snap }
            if let row = await fetchHKLatest(secucode: secucode) {
                merge(row.toFundamentals(), into: &snap.fundamentals)
            }
        }
        return snap
    }

    // MARK: - A-share (RPT_LICO_FN_CPD)

    /// Pulls the most recent report for an A-share code. Sorted by REPORTDATE
    /// desc and limited to 1; `pageSize` would let us pull YoY trend later
    /// but the LLM only needs the latest line plus its YoY ratios.
    private func fetchAShareLatest(code: String) async -> AShareRow? {
        var c = URLComponents(string: "https://datacenter-web.eastmoney.com/api/data/v1/get")!
        c.queryItems = [
            .init(name: "reportName", value: "RPT_LICO_FN_CPD"),
            .init(name: "columns", value: "ALL"),
            .init(name: "filter", value: "(SECURITY_CODE=\"\(code)\")"),
            .init(name: "pageNumber", value: "1"),
            .init(name: "pageSize", value: "1"),
            .init(name: "sortColumns", value: "REPORTDATE"),
            .init(name: "sortTypes", value: "-1"),
            .init(name: "source", value: "HSF10"),
            .init(name: "client", value: "PC"),
        ]
        guard let url = c.url else { return nil }
        guard let payload: ResultEnvelope<AShareRow> = await get(url) else { return nil }
        return payload.result?.data?.first
    }

    // MARK: - HK (RPT_HKF10_FN_MAININDICATOR)

    private func fetchHKLatest(secucode: String) async -> HKRow? {
        var c = URLComponents(string: "https://datacenter.eastmoney.com/securities/api/data/v1/get")!
        c.queryItems = [
            .init(name: "reportName", value: "RPT_HKF10_FN_MAININDICATOR"),
            .init(name: "columns", value: "ALL"),
            .init(name: "filter", value: "(SECUCODE=\"\(secucode)\")"),
            .init(name: "pageNumber", value: "1"),
            .init(name: "pageSize", value: "1"),
            .init(name: "sortColumns", value: "STD_REPORT_DATE"),
            .init(name: "sortTypes", value: "-1"),
            .init(name: "source", value: "F10"),
            .init(name: "client", value: "PC"),
        ]
        guard let url = c.url else { return nil }
        guard let payload: ResultEnvelope<HKRow> = await get(url) else { return nil }
        return payload.result?.data?.first
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ url: URL) async -> T? {
        await limiter.acquire(host: url.host ?? "")
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://emweb.securities.eastmoney.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Merge

    /// Adds financial fields without overwriting any existing entry the base
    /// provider already populated (PE, PB, 总市值, etc.). Empty / nil-derived
    /// strings are dropped so the merged dict only carries usable lines.
    private func merge(_ extras: [(String, String?)],
                       into target: inout [String: String])
    {
        for (key, value) in extras {
            guard let v = value, !v.isEmpty, target[key] == nil else { continue }
            target[key] = v
        }
    }

    // MARK: - Wire types

    /// Generic envelope for the two `datacenter` endpoints — both return
    /// `{result: {data: [...]}}` on success and `{result: null, success:
    /// false, message: ...}` on failure.
    private struct ResultEnvelope<Row: Decodable>: Decodable {
        struct Inner: Decodable { let data: [Row]? }
        let result: Inner?
    }

    private struct AShareRow: Decodable {
        let REPORTDATE: String?
        let QDATE: String?              // e.g. "2025Q1"
        let BASIC_EPS: Double?
        let TOTAL_OPERATE_INCOME: Double?
        let PARENT_NETPROFIT: Double?
        let WEIGHTAVG_ROE: Double?
        let YSTZ: Double?               // 营收 YoY %
        let SJLTZ: Double?              // 净利 YoY %
        let BPS: Double?
        let MGJYXJJE: Double?           // 每股经营现金流
        let XSMLL: Double?              // 销售毛利率 %

        /// Render the row into ordered (label, value) pairs that the merge
        /// helper drops into `fundamentals`. Ordering doesn't actually matter
        /// since the dict is unordered, but keeping it stable here makes
        /// fixture diffs readable.
        func toFundamentals() -> [(String, String?)] {
            let period = QDATE ?? REPORTDATE.flatMap { String($0.prefix(10)) }
            return [
                ("报告期",    period),
                ("营业总收入", TOTAL_OPERATE_INCOME.map(Formatting.bigCNY)),
                ("营收 YoY",  YSTZ.map(Formatting.percent)),
                ("归母净利润", PARENT_NETPROFIT.map(Formatting.bigCNY)),
                ("净利 YoY",  SJLTZ.map(Formatting.percent)),
                ("毛利率",    XSMLL.map(Formatting.percent)),
                ("加权 ROE",  WEIGHTAVG_ROE.map(Formatting.percent)),
                ("EPS",      BASIC_EPS.map { String(format: "%.2f", $0) }),
                ("每股净资产", BPS.map { String(format: "%.2f", $0) }),
                ("每股经营现金流", MGJYXJJE.map { String(format: "%.2f", $0) }),
            ]
        }
    }

    private struct HKRow: Decodable {
        let REPORT_TYPE: String?        // e.g. "2026年一季报"
        let STD_REPORT_DATE: String?
        let BASIC_EPS: Double?
        let OPERATE_INCOME: Double?
        let OPERATE_INCOME_YOY: Double?
        let HOLDER_PROFIT: Double?      // 归母净利润
        let HOLDER_PROFIT_YOY: Double?
        let GROSS_PROFIT_RATIO: Double?
        let NET_PROFIT_RATIO: Double?
        let ROE_AVG: Double?
        let ROE_YEARLY: Double?
        let DEBT_ASSET_RATIO: Double?
        let NETCASH_OPERATE: Double?
        let PER_NETCASH_OPERATE: Double?

        func toFundamentals() -> [(String, String?)] {
            let period = REPORT_TYPE
                ?? STD_REPORT_DATE.flatMap { String($0.prefix(10)) }
            return [
                ("报告期",    period),
                ("营业收入",   OPERATE_INCOME.map(Formatting.bigCNY)),
                ("营收 YoY",  OPERATE_INCOME_YOY.map(Formatting.percent)),
                ("归母净利润", HOLDER_PROFIT.map(Formatting.bigCNY)),
                ("净利 YoY",  HOLDER_PROFIT_YOY.map(Formatting.percent)),
                ("毛利率",    GROSS_PROFIT_RATIO.map(Formatting.percent)),
                ("净利率",    NET_PROFIT_RATIO.map(Formatting.percent)),
                ("ROE",      ROE_AVG.map(Formatting.percent)),
                ("ROE 年化", ROE_YEARLY.map(Formatting.percent)),
                ("资产负债率", DEBT_ASSET_RATIO.map(Formatting.percent)),
                ("经营现金流", NETCASH_OPERATE.map(Formatting.bigCNY)),
                ("每股经营现金流", PER_NETCASH_OPERATE.map { String(format: "%.2f", $0) }),
                ("EPS",      BASIC_EPS.map { String(format: "%.2f", $0) }),
            ]
        }
    }
}

/// Number formatting shared by the EastMoney decorators. Lives at file
/// scope so future decorators (FundFlow / News) can reuse it without each
/// one re-implementing 亿 / 万 buckets.
enum Formatting {
    static func percent(_ value: Double) -> String {
        String(format: "%+.2f%%", value)
    }
    static func bigCNY(_ value: Double) -> String {
        let abs = Swift.abs(value)
        switch abs {
        case 1e12...: return String(format: "%.2f万亿", value / 1e12)
        case 1e8...:  return String(format: "%.2f亿", value / 1e8)
        case 1e4...:  return String(format: "%.1f万", value / 1e4)
        default:      return String(format: "%.0f", value)
        }
    }
}
