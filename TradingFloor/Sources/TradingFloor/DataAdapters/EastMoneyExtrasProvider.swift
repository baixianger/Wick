import Foundation

/// Standalone fetchers for the four free EastMoney (东方财富) "extras" the chat
/// agent (Wicker) calls on demand for A-share / HK analysis — a free
/// replacement for tushare's points-gated data:
///
///   • 资金流 (fund flow)      — `fundFlow(symbol:days:)`
///   • F10 财务指标 (financials) — `financials(symbol:)`
///   • 龙虎榜 (dragon-tiger)    — `dragonTiger(symbol:)` / `dragonTigerLatest()`
///   • 涨停板 (limit-up pool)   — `limitUpPool(date:)`
///
/// Foundation-only (the `TradingFloor` package builds on Linux); no key.
/// Mirrors `EastMoneyMarketDataProvider`'s networking: shared UA + `Referer`,
/// routed through `HTTPRateLimiter`. Decoders are deliberately forgiving —
/// EastMoney serves `"-"` / `null` for missing numerics, so every field is
/// optional and the `"-"`-as-missing quirk is handled per field.
///
/// These return STRUCTS, not snapshot decorations: the always-on AgentTools
/// (`cn.*`) format them into compact Chinese-labelled summaries. The existing
/// `EastMoney*Decorator`s remain the snapshot-side path; this is the
/// agent-callable path that lets Wicker pull these on request for any CN
/// ticker even when no full snapshot was built.
public struct EastMoneyExtrasProvider: Sendable {
    public let session: URLSession
    public let limiter: HTTPRateLimiter

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public init(session: URLSession = .shared,
                limiter: HTTPRateLimiter = HTTPRateLimiter(minInterval: 0.2))
    {
        self.session = session
        self.limiter = limiter
    }

    // MARK: - 1) 资金流 (fund flow)

    /// One day of main-force capital flow. Amounts are CNY (signed: net
    /// inflow positive). `mainPct` is 主力净占比 (share of turnover, %).
    public struct FundFlowDay: Sendable {
        public let date: String
        public let main: Double        // 主力净流入额
        public let small: Double       // 小单净流入
        public let medium: Double      // 中单净流入
        public let big: Double         // 大单净流入
        public let superBig: Double    // 超大单净流入
        public let mainPct: Double     // 主力净占比 %
    }

    /// Last `days` sessions of capital flow for an A-share, oldest → newest.
    /// Empty for HK (market 116 carries no order-size disclosure) and on any
    /// failure. `secid` is the EastMoney `1.600519` / `0.000001` form.
    public func fundFlow(symbol: String, days: Int = 5) async -> [FundFlowDay] {
        guard let secid = CNSymbol.eastMoneySecid(symbol),
              let market = CNSymbol.market(symbol),
              market == .shanghai || market == .shenzhen
        else { return [] }

        var c = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/fflow/daykline/get")!
        c.queryItems = [
            .init(name: "lmt", value: "0"),
            .init(name: "klt", value: "101"),
            .init(name: "secid", value: secid),
            .init(name: "fields1", value: "f1,f2,f3,f7"),
            .init(name: "fields2",
                  value: "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61,f62,f63,f64,f65"),
        ]
        guard let url = c.url,
              let payload: FFlowPayload = await get(url, referer: "https://quote.eastmoney.com/"),
              let klines = payload.data?.klines
        else { return [] }

        // CSV (fields2 order): 日期, 主力净流入(f52), 小单(f53), 中单(f54),
        // 大单(f55), 超大单(f56), 主力净占比%(f57), 小单%, 中单%, 大单%, 超大单%…
        let rows: [FundFlowDay] = klines.compactMap { row in
            let p = row.split(separator: ",", omittingEmptySubsequences: false)
            guard p.count >= 7,
                  let main = Double(p[1]),
                  let small = Double(p[2]),
                  let medium = Double(p[3]),
                  let big = Double(p[4]),
                  let superBig = Double(p[5]),
                  let mainPct = Double(p[6])
            else { return nil }
            return FundFlowDay(date: String(p[0]), main: main, small: small,
                               medium: medium, big: big, superBig: superBig,
                               mainPct: mainPct)
        }
        return rows.suffix(max(days, 1)).map { $0 }
    }

    // MARK: - 2) F10 财务指标 (financials)

    /// One reporting period from `RPT_F10_FINANCE_MAINFINADATA`. Amounts are
    /// CNY; growth / ratio fields are already percentages.
    public struct FinanceReport: Sendable {
        public let reportName: String?   // "2026一季报"
        public let reportDate: String?   // "2026-03-31"
        public let revenue: Double?      // 营业总收入
        public let revenueYoY: Double?   // 营收同比 %
        public let netProfit: Double?    // 归母净利润
        public let netProfitYoY: Double? // 净利润同比 %
        public let eps: Double?          // 基本每股收益
        public let roe: Double?          // 净资产收益率(加权) %
        public let grossMargin: Double?  // 销售毛利率 %
        public let netMargin: Double?    // 销售净利率 %
        public let debtRatio: Double?    // 资产负债率 %
        public let bps: Double?          // 每股净资产
    }

    /// Latest few reporting periods for a CN ticker (newest first). A-share
    /// uses the F10 main-indicator table; HK falls back to the HK F10 table the
    /// snapshot decorator already uses, normalised into the same struct.
    public func financials(symbol: String, periods: Int = 6) async -> [FinanceReport] {
        guard let market = CNSymbol.market(symbol),
              let secucode = CNSymbol.eastMoneyF10Secucode(symbol)
        else { return [] }

        switch market {
        case .shanghai, .shenzhen:
            var c = URLComponents(string: "https://datacenter-web.eastmoney.com/api/data/v1/get")!
            c.queryItems = [
                .init(name: "reportName", value: "RPT_F10_FINANCE_MAINFINADATA"),
                .init(name: "columns", value: "ALL"),
                .init(name: "filter", value: "(SECUCODE=\"\(secucode)\")"),
                .init(name: "pageNumber", value: "1"),
                .init(name: "pageSize", value: String(max(periods, 1))),
                .init(name: "sortColumns", value: "REPORT_DATE"),
                .init(name: "sortTypes", value: "-1"),
                .init(name: "source", value: "WEB"),
                .init(name: "client", value: "WEB"),
            ]
            guard let url = c.url,
                  let payload: ResultEnvelope<MainFinaRow> = await get(url, referer: "https://emweb.securities.eastmoney.com/"),
                  let data = payload.result?.data
            else { return [] }
            return data.map { $0.normalized() }
        case .hongKong:
            var c = URLComponents(string: "https://datacenter.eastmoney.com/securities/api/data/v1/get")!
            c.queryItems = [
                .init(name: "reportName", value: "RPT_HKF10_FN_MAININDICATOR"),
                .init(name: "columns", value: "ALL"),
                .init(name: "filter", value: "(SECUCODE=\"\(secucode)\")"),
                .init(name: "pageNumber", value: "1"),
                .init(name: "pageSize", value: String(max(periods, 1))),
                .init(name: "sortColumns", value: "STD_REPORT_DATE"),
                .init(name: "sortTypes", value: "-1"),
                .init(name: "source", value: "F10"),
                .init(name: "client", value: "PC"),
            ]
            guard let url = c.url,
                  let payload: ResultEnvelope<HKFinaRow> = await get(url, referer: "https://emweb.securities.eastmoney.com/"),
                  let data = payload.result?.data
            else { return [] }
            return data.map { $0.normalized() }
        }
    }

    // MARK: - 3) 龙虎榜 (dragon-tiger)

    public struct BillboardEntry: Sendable {
        public let date: String           // "2026-06-12"
        public let code: String?
        public let name: String?
        public let explanation: String?   // 上榜原因
        public let explain: String?       // 席位解读 (机构/游资)
        public let netAmount: Double?     // 净买入额 (signed)
        public let buyAmount: Double?
        public let sellAmount: Double?
        public let changeRate: Double?    // 当日涨跌幅 %
        public let market: String?        // 交易市场 (上交所主板 …)
    }

    /// Recent billboard appearances for ONE A-share (newest first), or — when
    /// `symbol` is nil — the latest market-wide list. `pageSize` caps rows.
    public func dragonTiger(symbol: String?, pageSize: Int = 30) async -> [BillboardEntry] {
        var filter: String? = nil
        if let symbol {
            guard let market = CNSymbol.market(symbol),
                  market == .shanghai || market == .shenzhen,
                  let code = CNSymbol.parse(symbol)?.split(separator: ".").first.map(String.init)
            else { return [] }
            filter = "(SECURITY_CODE=\"\(code)\")"
        }
        var c = URLComponents(string: "https://datacenter-web.eastmoney.com/api/data/v1/get")!
        var items: [URLQueryItem] = [
            .init(name: "reportName", value: "RPT_DAILYBILLBOARD_DETAILS"),
            .init(name: "columns", value: "ALL"),
            .init(name: "pageNumber", value: "1"),
            .init(name: "pageSize", value: String(max(pageSize, 1))),
            .init(name: "sortColumns", value: "TRADE_DATE"),
            .init(name: "sortTypes", value: "-1"),
            .init(name: "source", value: "WEB"),
            .init(name: "client", value: "WEB"),
        ]
        if let filter { items.append(.init(name: "filter", value: filter)) }
        c.queryItems = items
        guard let url = c.url,
              let payload: ResultEnvelope<BillboardRow> = await get(url, referer: "https://data.eastmoney.com/"),
              let data = payload.result?.data
        else { return [] }
        return data.map { $0.normalized() }
    }

    // MARK: - 4) 涨停板 (limit-up pool)

    public struct LimitUpStock: Sendable {
        public let code: String
        public let name: String
        public let price: Double          // 最新价
        public let changePct: Double      // 涨跌幅 %
        public let amount: Double         // 成交额
        public let sealAmount: Double     // 封单额 (fund)
        public let consecutive: Int       // 连板数 (lbc)
        public let firstSealTime: String? // 首次封板时间 "HH:MM:SS"
        public let industry: String?      // 行业板块
    }

    public struct LimitUpPool: Sendable {
        public let date: String           // "20260612"
        public let total: Int             // 涨停家数
        public let stocks: [LimitUpStock] // sorted by 连板 then 封单额, desc
    }

    /// Whole-market limit-up pool for a date (default = most recent trading
    /// day). `date` is `yyyyMMdd`; the endpoint snaps an unknown / future date
    /// to the latest available list and reports the resolved `qdate`. Returns
    /// `nil` on failure or an empty pool (e.g. queried pre-open before any
    /// stock has sealed) so the tool can report that cleanly.
    public func limitUpPool(date: String? = nil) async -> LimitUpPool? {
        let day = date ?? Self.todayYYYYMMDD()
        var c = URLComponents(string: "https://push2ex.eastmoney.com/getTopicZTPool")!
        c.queryItems = [
            .init(name: "ut", value: "7eea3edcaed734bea9cbfc24409ed989"),
            .init(name: "dpt", value: "wz.ztzt"),
            .init(name: "Pageindex", value: "0"),
            .init(name: "pagesize", value: "170"),
            .init(name: "sort", value: "fbt:asc"),
            .init(name: "date", value: day),
        ]
        guard let url = c.url,
              let payload: ZTPoolPayload = await get(url, referer: "https://quote.eastmoney.com/"),
              let pool = payload.data?.pool, !pool.isEmpty
        else { return nil }

        let resolved = payload.data?.qdate.map(String.init) ?? day
        let stocks = pool.map { r -> LimitUpStock in
            LimitUpStock(
                code: r.c ?? "",
                name: r.n ?? "",
                // EastMoney serves price as integer ×1000 (52750 → 52.75).
                price: (r.p ?? 0) / 1000.0,
                changePct: r.zdp ?? 0,
                amount: r.amount ?? 0,
                sealAmount: r.fund ?? 0,
                consecutive: r.lbc ?? 1,
                firstSealTime: Self.hms(r.fbt),
                industry: (r.hybk?.isEmpty == false) ? r.hybk : nil)
        }
        return LimitUpPool(date: resolved, total: payload.data?.tc ?? stocks.count, stocks: stocks)
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ url: URL, referer: String) async -> T? {
        await limiter.acquire(host: url.host ?? "")
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Date helpers

    private static func todayYYYYMMDD() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: Date())
    }

    /// EastMoney 封板时间 is `HHMMSS` as an int (92500 → "09:25:00"). Returns
    /// nil for 0 / missing.
    private static func hms(_ v: Int?) -> String? {
        guard let v, v > 0 else { return nil }
        let s = String(format: "%06d", v)
        return "\(s.prefix(2)):\(s.dropFirst(2).prefix(2)):\(s.suffix(2))"
    }

    // MARK: - Wire types

    private struct FFlowPayload: Decodable {
        struct Inner: Decodable { let klines: [String]? }
        let data: Inner?
    }

    /// Shared datacenter envelope (`{result:{data:[…]}}`, or `result:null`).
    private struct ResultEnvelope<Row: Decodable>: Decodable {
        struct Inner: Decodable { let data: [Row]? }
        let result: Inner?
    }

    /// A-share F10 row. Forgiving: every numeric is `Forgiving<Double>` so
    /// `"-"` / null degrade to nil rather than failing the whole decode.
    private struct MainFinaRow: Decodable {
        let REPORT_DATE_NAME: String?
        let REPORT_DATE: String?
        let TOTALOPERATEREVE: ForgivingDouble?
        let TOTALOPERATEREVETZ: ForgivingDouble?
        let PARENTNETPROFIT: ForgivingDouble?
        let PARENTNETPROFITTZ: ForgivingDouble?
        let EPSJB: ForgivingDouble?
        let ROEJQ: ForgivingDouble?
        let XSMLL: ForgivingDouble?
        let XSJLL: ForgivingDouble?
        let ZCFZL: ForgivingDouble?
        let BPS: ForgivingDouble?

        func normalized() -> FinanceReport {
            FinanceReport(
                reportName: REPORT_DATE_NAME,
                reportDate: REPORT_DATE.map { String($0.prefix(10)) },
                revenue: TOTALOPERATEREVE?.value,
                revenueYoY: TOTALOPERATEREVETZ?.value,
                netProfit: PARENTNETPROFIT?.value,
                netProfitYoY: PARENTNETPROFITTZ?.value,
                eps: EPSJB?.value,
                roe: ROEJQ?.value,
                grossMargin: XSMLL?.value,
                netMargin: XSJLL?.value,
                debtRatio: ZCFZL?.value,
                bps: BPS?.value)
        }
    }

    /// HK F10 row (subset of `RPT_HKF10_FN_MAININDICATOR`). Field names follow
    /// EastMoney's English HK schema.
    private struct HKFinaRow: Decodable {
        let STD_REPORT_DATE: String?
        let OPERATE_INCOME: ForgivingDouble?
        let OPERATE_INCOME_YOY: ForgivingDouble?
        let HOLDER_PROFIT: ForgivingDouble?
        let HOLDER_PROFIT_YOY: ForgivingDouble?
        let BASIC_EPS: ForgivingDouble?
        let ROE_AVG: ForgivingDouble?
        let GROSS_PROFIT_RATIO: ForgivingDouble?
        let NET_PROFIT_RATIO: ForgivingDouble?
        let DEBT_ASSET_RATIO: ForgivingDouble?

        func normalized() -> FinanceReport {
            FinanceReport(
                reportName: STD_REPORT_DATE.map { String($0.prefix(10)) },
                reportDate: STD_REPORT_DATE.map { String($0.prefix(10)) },
                revenue: OPERATE_INCOME?.value,
                revenueYoY: OPERATE_INCOME_YOY?.value,
                netProfit: HOLDER_PROFIT?.value,
                netProfitYoY: HOLDER_PROFIT_YOY?.value,
                eps: BASIC_EPS?.value,
                roe: ROE_AVG?.value,
                grossMargin: GROSS_PROFIT_RATIO?.value,
                netMargin: NET_PROFIT_RATIO?.value,
                debtRatio: DEBT_ASSET_RATIO?.value,
                bps: nil)
        }
    }

    private struct BillboardRow: Decodable {
        let TRADE_DATE: String?
        let SECURITY_CODE: String?
        let SECURITY_NAME_ABBR: String?
        let EXPLANATION: String?
        let EXPLAIN: String?
        let BILLBOARD_NET_AMT: ForgivingDouble?
        let BILLBOARD_BUY_AMT: ForgivingDouble?
        let BILLBOARD_SELL_AMT: ForgivingDouble?
        let CHANGE_RATE: ForgivingDouble?
        let TRADE_MARKET: String?

        func normalized() -> BillboardEntry {
            BillboardEntry(
                date: TRADE_DATE.map { String($0.prefix(10)) } ?? "",
                code: SECURITY_CODE,
                name: SECURITY_NAME_ABBR,
                explanation: EXPLANATION,
                explain: EXPLAIN,
                netAmount: BILLBOARD_NET_AMT?.value,
                buyAmount: BILLBOARD_BUY_AMT?.value,
                sellAmount: BILLBOARD_SELL_AMT?.value,
                changeRate: CHANGE_RATE?.value,
                market: TRADE_MARKET)
        }
    }

    private struct ZTPoolPayload: Decodable {
        struct Inner: Decodable {
            let tc: Int?
            let qdate: Int?
            let pool: [Row]?
        }
        struct Row: Decodable {
            let c: String?      // code
            let n: String?      // name
            let p: Double?      // price ×1000
            let zdp: Double?    // 涨跌幅 %
            let amount: Double? // 成交额
            let fund: Double?   // 封单额
            let lbc: Int?       // 连板数
            let fbt: Int?       // 首次封板 HHMMSS
            let hybk: String?   // 行业板块
        }
        let data: Inner?
    }
}

/// `"-"` / null / numeric-as-string forgiving `Double`. EastMoney's datacenter
/// tables serve a real number, JSON `null`, or the string `"-"` for "missing";
/// default `Decodable` raises on the last two. Wrapping a column in this type
/// makes the whole-row decode succeed and surfaces a clean `nil`.
struct ForgivingDouble: Decodable, Sendable {
    let value: Double?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d; return }
        if let s = try? c.decode(String.self), s != "-", let d = Double(s) { value = d; return }
        value = nil
    }
}
