import Foundation

/// Appends a 融资融券 (margin trading) line to `capitalFlow` for A-share
/// tickers — the latest 融资余额 (financing balance) with its day-over-day
/// growth and its share of free-float cap, plus the day's 融资净买入 and the
/// 融券余额 (securities-lending balance). Margin balance is the second number
/// a CN desk quotes after 主力净流入: a rising 融资余额 means leveraged longs
/// are crowding in, a falling one means de-grossing, and 融券 spikes flag
/// short pressure. It has no US analogue in this data chain.
///
/// Source: EastMoney `datacenter` table `RPTA_WEB_RZRQ_GGMX` (per-stock
/// margin detail, no key), filtered on `SCODE="600519"` and sorted by `DATE`
/// desc so row 0 is the most recent disclosure (margin data lags one trading
/// day). Fields used:
///   • `RZYE`          融资余额 (CNY)
///   • `FIN_BALANCE_GR` 融资余额较上一日增长率 (%)
///   • `RZYEZB`         融资余额占流通市值 (%)
///   • `RZJME`          当日融资净买入 (CNY, signed)
///   • `RQYE`           融券余额 (CNY)
///
/// Hong Kong is skipped: 融资融券 is a mainland exchange mechanism and the
/// table carries no HK rows, so the guard is by-market rather than
/// best-effort. Like `EastMoneyFundFlowDecorator` this lands in `capitalFlow`
/// (read by the dedicated 资金面 analyst), is best-effort (any failure →
/// pass-through), and is cached per `"symbol|day"`.
public actor EastMoneyMarginDecorator: MarketDataProvider {
    private let base: any MarketDataProvider
    private let session: URLSession
    private let limiter: HTTPRateLimiter
    private var cache: [String: String] = [:]   // "symbol|day" → line

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
        guard let market = CNSymbol.market(snap.symbol),
              market == .shanghai || market == .shenzhen
        else { return snap }
        let code = snap.symbol.split(separator: ".").first.map(String.init) ?? ""
        guard !code.isEmpty else { return snap }

        let key = "\(snap.symbol)|\(TradingDay.key(asOf))"
        let line: String
        if let cached = cache[key] {
            line = cached
        } else {
            line = await marginLine(code: code)
            if !line.isEmpty { cache[key] = line }
        }
        if !line.isEmpty {
            snap.capitalFlow = snap.capitalFlow.isEmpty
                ? line
                : snap.capitalFlow + "\n" + line
        }
        return snap
    }

    private func marginLine(code: String) async -> String {
        var c = URLComponents(string: "https://datacenter-web.eastmoney.com/api/data/v1/get")!
        c.queryItems = [
            .init(name: "reportName", value: "RPTA_WEB_RZRQ_GGMX"),
            .init(name: "columns", value: "ALL"),
            .init(name: "filter", value: "(SCODE=\"\(code)\")"),
            .init(name: "pageNumber", value: "1"),
            .init(name: "pageSize", value: "1"),
            .init(name: "sortColumns", value: "DATE"),
            .init(name: "sortTypes", value: "-1"),
            .init(name: "source", value: "WEB"),
            .init(name: "client", value: "WEB"),
        ]
        guard let url = c.url else { return "" }
        await limiter.acquire(host: url.host ?? "")
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://data.eastmoney.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let env = try? JSONDecoder().decode(Envelope.self, from: data),
              let row = env.result?.data?.first
        else { return "" }

        var parts: [String] = []
        if let rzye = row.RZYE {
            var financing = "融资余额 \(Formatting.bigCNY(rzye))"
            if let gr = row.FIN_BALANCE_GR { financing += " (\(Formatting.percent(gr)))" }
            parts.append(financing)
        }
        if let net = row.RZJME { parts.append("融资净买入 \(Formatting.bigCNY(net))") }
        if let zb = row.RZYEZB { parts.append("占流通市值 \(Formatting.percent(zb))") }
        if let rqye = row.RQYE { parts.append("融券余额 \(Formatting.bigCNY(rqye))") }
        guard !parts.isEmpty else { return "" }
        return "融资融券: " + parts.joined(separator: "; ")
    }

    // MARK: - Wire types

    private struct Envelope: Decodable {
        struct Inner: Decodable { let data: [Row]? }
        let result: Inner?
    }

    private struct Row: Decodable {
        let RZYE: Double?            // 融资余额
        let FIN_BALANCE_GR: Double?  // 融资余额较上一日增长率 %
        let RZYEZB: Double?          // 融资余额占流通市值 %
        let RZJME: Double?           // 当日融资净买入 (signed)
        let RQYE: Double?            // 融券余额
    }
}
