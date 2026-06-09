import Foundation

/// Appends a 资金流向 (main-force capital flow) line to `capitalFlow` for
/// A-share tickers — today's 主力/超大单 net inflow with its share of
/// turnover, plus the 5-day cumulative. A-share price action is heavily
/// flow-narrated (主力净流入 is the first number a CN trader quotes), and it
/// has no analogue in the US data chain.
///
/// Source: EastMoney `push2his …/stock/fflow/daykline/get` (no key) —
/// daily rows of net inflow by order size. 主力 = 超大单 + 大单 by
/// EastMoney's definition. Hong Kong tickers are skipped: the endpoint
/// returns no data for market 116 (HK has no mainland-style order-size
/// disclosure), so the guard is by-market rather than best-effort.
///
/// Goes into `capitalFlow` (not `technicals` or `macro`): on the Chinese
/// desk a dedicated 资金面 (`capital`) analyst reads this field, so the
/// flow signal gets its own voice rather than being buried in the
/// technician's RSI/MACD block. Per-symbol-per-day cache.
public actor EastMoneyFundFlowDecorator: MarketDataProvider {
    private let base: any MarketDataProvider
    private let session: URLSession
    private let limiter: HTTPRateLimiter
    private var cache: [String: String] = [:]   // "symbol|day" → line

    public init(base: any MarketDataProvider,
                session: URLSession = .shared,
                limiter: HTTPRateLimiter = HTTPRateLimiter())
    {
        self.base = base
        self.session = session
        self.limiter = limiter
    }

    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        var snap = try await base.snapshot(symbol: symbol, asOf: asOf)
        guard let market = CNSymbol.market(snap.symbol),
              market == .shanghai || market == .shenzhen,
              let secid = CNSymbol.eastMoneySecid(snap.symbol)
        else { return snap }

        let key = "\(snap.symbol)|\(TradingDay.key(asOf))"
        let line: String
        if let cached = cache[key] {
            line = cached
        } else {
            line = await fundFlowLine(secid: secid)
            if !line.isEmpty { cache[key] = line }
        }
        if !line.isEmpty {
            snap.capitalFlow = snap.capitalFlow.isEmpty
                ? line
                : snap.capitalFlow + "\n" + line
        }
        return snap
    }

    private func fundFlowLine(secid: String) async -> String {
        var c = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/fflow/daykline/get")!
        c.queryItems = [
            .init(name: "secid", value: secid),
            .init(name: "klt", value: "101"),
            .init(name: "lmt", value: "5"),
            .init(name: "fields1", value: "f1,f2,f3,f7"),
            .init(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"),
        ]
        guard let url = c.url else { return "" }
        await limiter.acquire(host: url.host ?? "")
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let klines = payload["klines"] as? [String]
        else { return "" }

        // Row CSV (fields2 order): 日期, 主力净流入, 小单, 中单, 大单,
        // 超大单 (amounts in CNY), then the same five as % of turnover.
        let rows: [(date: String, main: Double, xl: Double, mainPct: Double)] =
            klines.compactMap { row in
                let p = row.split(separator: ",")
                guard p.count >= 11,
                      let main = Double(p[1]),
                      let xl = Double(p[5]),
                      let mainPct = Double(p[6])
                else { return nil }
                return (String(p[0]), main, xl, mainPct)
            }
        guard let today = rows.last else { return "" }

        var parts = [
            "今日主力净流入 \(Formatting.bigCNY(today.main)) (占成交额 \(Formatting.percent(today.mainPct)))",
            "超大单 \(Formatting.bigCNY(today.xl))",
        ]
        if rows.count > 1 {
            let cumulative = rows.reduce(0) { $0 + $1.main }
            parts.append("近\(rows.count)日主力累计 \(Formatting.bigCNY(cumulative))")
        }
        return "资金流向: " + parts.joined(separator: "; ")
    }
}
