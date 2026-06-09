import Foundation

/// Appends a 龙虎榜 (dragon-tiger billboard) line to `capitalFlow` for
/// A-share tickers — but ONLY when the stock actually triggered the list
/// recently. A stock lands on the 龙虎榜 only on days its move / turnover /
/// amplitude crosses an exchange threshold, so most days there is nothing to
/// say and this decorator appends nothing (pass-through). When it does
/// appear, the seat composition — 机构 (institutions) vs 游资 (hot-money
/// desks) — and the net buy is exactly what a CN desk reads to judge whether
/// a move is "real" (institutional accumulation) or a one-day speculative
/// pump. No US analogue.
///
/// Source: EastMoney `datacenter` table `RPT_DAILYBILLBOARD_DETAILSNEW`
/// (per-stock billboard detail, no key), filtered on `SECURITY_CODE="600519"`
/// and sorted by `TRADE_DATE` desc so row 0 is the latest appearance. Because
/// the table is the stock's full history, the latest row may be years old —
/// the decorator only renders it when `TRADE_DATE` is within
/// `recencyWindow` (default 5 calendar days) of `asOf`, otherwise it treats
/// the stock as "not on a recent billboard" and appends nothing. Fields used:
///   • `TRADE_DATE`        billboard date
///   • `NET_BS_AMT`        净买入额 (CNY, signed; = BUY − SELL on the seats)
///   • `EXPLANATION`       上榜原因 (why it triggered)
///   • `EXPLAIN`           席位解读, e.g. "5家机构卖出，成功率48.38%"
///
/// Hong Kong is skipped (no mainland 龙虎榜). Best-effort, A-share-only,
/// cached per `"symbol|day"` (a negative/empty result is cached too so a
/// non-listed stock isn't re-fetched within the day).
public actor EastMoneyBillboardDecorator: MarketDataProvider {
    private let base: any MarketDataProvider
    private let session: URLSession
    private let limiter: HTTPRateLimiter
    private let recencyWindow: TimeInterval
    private var cache: [String: String] = [:]   // "symbol|day" → line ("" = checked, none)

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// `recencyDays` — how many calendar days back from `asOf` still counts as
    /// "on a recent billboard". 5 covers a normal trading week plus the
    /// one-day publication lag without resurfacing stale appearances.
    public init(base: any MarketDataProvider,
                session: URLSession = .shared,
                limiter: HTTPRateLimiter = HTTPRateLimiter(minInterval: 0.2),
                recencyDays: Int = 5)
    {
        self.base = base
        self.session = session
        self.limiter = limiter
        self.recencyWindow = TimeInterval(recencyDays) * 86_400
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
            line = await billboardLine(code: code, asOf: asOf)
            // Cache the verdict either way: "" means "checked today, not
            // listed", so a non-listed stock isn't re-fetched all day.
            cache[key] = line
        }
        if !line.isEmpty {
            snap.capitalFlow = snap.capitalFlow.isEmpty
                ? line
                : snap.capitalFlow + "\n" + line
        }
        return snap
    }

    private func billboardLine(code: String, asOf: Date) async -> String {
        var c = URLComponents(string: "https://datacenter-web.eastmoney.com/api/data/v1/get")!
        c.queryItems = [
            .init(name: "reportName", value: "RPT_DAILYBILLBOARD_DETAILSNEW"),
            .init(name: "columns", value: "ALL"),
            .init(name: "filter", value: "(SECURITY_CODE=\"\(code)\")"),
            .init(name: "pageNumber", value: "1"),
            .init(name: "pageSize", value: "1"),
            .init(name: "sortColumns", value: "TRADE_DATE"),
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
              let row = env.result?.data?.first,
              let rawDate = row.TRADE_DATE
        else { return "" }

        // Only surface a recent appearance. The table holds the stock's whole
        // billboard history, so a years-old top row must NOT be rendered as if
        // the stock is on today's list.
        let dayStr = String(rawDate.prefix(10))   // "2026-06-09 00:00:00" → date
        guard let tradeDate = Self.dateFormatter.date(from: dayStr),
              asOf.timeIntervalSince(tradeDate) <= recencyWindow,
              asOf.timeIntervalSince(tradeDate) >= -recencyWindow
        else { return "" }

        var parts = ["\(dayStr) 上榜"]
        if let net = row.NET_BS_AMT { parts.append("净买入 \(Formatting.bigCNY(net))") }
        // The seat read ("N家机构买入/卖出，…") is the most actionable line —
        // it distinguishes institutional from 游资 flow.
        if let explain = row.EXPLAIN, !explain.isEmpty { parts.append(explain) }
        else if let reason = row.EXPLANATION, !reason.isEmpty { parts.append(reason) }
        return "龙虎榜: " + parts.joined(separator: "; ")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Wire types

    private struct Envelope: Decodable {
        struct Inner: Decodable { let data: [Row]? }
        let result: Inner?
    }

    private struct Row: Decodable {
        let TRADE_DATE: String?
        let NET_BS_AMT: Double?    // 净买入额 (signed)
        let EXPLANATION: String?   // 上榜原因
        let EXPLAIN: String?       // 席位解读 (机构/游资)
    }
}
