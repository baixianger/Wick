import Foundation

/// Appends the latest **northbound (Stock Connect / 北向) shareholding** line
/// to `fundamentals` for A-share tickers — how many shares foreign投资者 hold
/// via CCASS and what fraction of the issued float that represents, e.g.
/// `北向持股 = 4.69% 流通股 (5873万股, 截至 2026Q1)`.
///
/// This is an **ownership-positioning fundamental, NOT a daily capital-flow
/// signal**. HKEX discontinued *daily* per-stock northbound holdings on
/// 19 Aug 2024; since then the figure is published **QUARTERLY** (the
/// preceding quarter, on the 5th northbound trading day after quarter-end).
/// EastMoney's per-stock northbound tables are frozen in mid-2024, so the
/// only surviving authoritative source is HKEX's CCASS Stock Connect search:
///
///   • Shanghai: `mutualmarket.aspx?t=sh`
///   • Shenzhen: `mutualmarket.aspx?t=sz`
///
/// Crucially, despite being an ASP.NET WebForms page, a **plain GET renders
/// the full latest-quarter list** in `pnlResult` — no `__VIEWSTATE` POST and
/// no client JS are required — so this stays Foundation-only / Linux-clean
/// for WickServer. The page is a FULL-LIST-by-date report (no per-stock
/// query), so we fetch the whole quarter's list ONCE, cache it keyed by the
/// shareholding date, and look up each ticker from the cache — one fetch per
/// market serves every A-share that quarter (mirrors the basket cache in
/// `CrossAssetContextDecorator`). HK / non-CN symbols pass through untouched.
///
/// The rendered value carries an explicit `YYYYQn` label derived from the
/// shareholding date so it can never be mistaken for daily data. A recency
/// guard refuses to render anything once the published quarter is more than
/// ~2 quarters behind `asOf`: if CCASS ever freezes (as the daily tables did),
/// the line silently disappears rather than showing a stale figure.
///
/// Goes into `fundamentals` (the 基本面 analyst's label→value map), NOT
/// `capitalFlow` — quarterly ownership is a holdings datum, not a flow. Sits
/// next to `EastMoneyFinancialProvider`, the closest quarterly-fundamentals
/// sibling, and reuses its file-scope `Formatting` helper. Best-effort: any
/// fetch / parse failure passes through, leaving `fundamentals` untouched.
public actor CCASSNorthboundDecorator: MarketDataProvider {
    private let base: any MarketDataProvider
    private let session: URLSession
    private let limiter: HTTPRateLimiter

    /// One parsed full-list per market, keyed by the shareholding date string
    /// (`"2026/03/31"`). `holdings` maps the 6-digit A-share code → row. The
    /// quarter cache amortises a single ~1.3 MB fetch across every ticker.
    private var cache: [CNSymbol.Market: ParsedList] = [:]

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public init(base: any MarketDataProvider,
                session: URLSession = .shared,
                limiter: HTTPRateLimiter = HTTPRateLimiter(minInterval: 0.5))
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

        guard let list = await list(for: market) else { return snap }

        // Recency guard: drop silently if the published quarter is stale
        // (> ~2 quarters / ~200 days behind asOf). Protects against CCASS
        // freezing the way the daily tables did in 2024.
        guard let date = list.date,
              asOf.timeIntervalSince(date) <= 200 * 86_400,
              asOf.timeIntervalSince(date) >= -7 * 86_400,   // tolerate small clock skew
              let row = list.holdings[code]
        else { return snap }

        let value = render(row: row, date: date)
        if snap.fundamentals["北向持股"] == nil {
            snap.fundamentals["北向持股"] = value
        }
        return snap
    }

    // MARK: - Quarter cache

    private func list(for market: CNSymbol.Market) async -> ParsedList? {
        if let cached = cache[market] { return cached }
        guard let parsed = await fetchAndParse(market: market) else { return nil }
        cache[market] = parsed
        return parsed
    }

    private func fetchAndParse(market: CNSymbol.Market) async -> ParsedList? {
        let t = (market == .shanghai) ? "sh" : "sz"
        guard let url = URL(string:
            "https://www3.hkexnews.hk/sdw/search/mutualmarket.aspx?t=\(t)")
        else { return nil }

        await limiter.acquire(host: url.host ?? "")
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        return Self.parse(html)
    }

    // MARK: - Parsing

    struct Row: Sendable {
        let shares: Double      // 持股数 (shares)
        let percent: String     // already-formatted, e.g. "4.69%"
    }

    struct ParsedList: Sendable {
        let date: Date?
        let dateLabel: String   // raw "2026/03/31" for diagnostics
        let holdings: [String: Row]
    }

    /// Parses the CCASS full-list HTML. The page is a flat table of
    /// `col-stock-code / col-stock-name / col-shareholding /
    /// col-shareholding-percent` cells. Two non-obvious points:
    ///   • `col-stock-code` holds HKEX's internal 5-digit Connect code
    ///     (`90519`), NOT the A-share code; the canonical 6-digit A-share
    ///     code lives in the name cell as `(A #600519)`. We key on the
    ///     `#NNNNNN` token.
    ///   • The shareholding date is the `<h2 class="ccass-heading">`
    ///     `Shareholding Date: 2026/03/31` — the authoritative quarter end,
    ///     distinct from the page's daily `today` reset value.
    /// Foundation-only regex; tolerant of partial markup (best-effort).
    static func parse(_ html: String) -> ParsedList? {
        let dateStr = firstMatch(
            in: html,
            pattern: #"Shareholding Date:\s*([0-9]{4}/[0-9]{2}/[0-9]{2})"#)

        // Each value cell is `<div class="mobile-list-body">VALUE</div>`.
        // Per row the cells appear in order: code, name (with `#NNNNNN`),
        // shareholding, percent. Walk the body values and group by 4.
        let bodies = allMatches(
            in: html,
            pattern: #"<div class="mobile-list-body">([^<]*)</div>"#)
        guard !bodies.isEmpty else { return nil }

        var holdings: [String: Row] = [:]
        var i = 0
        while i + 3 < bodies.count {
            let name = bodies[i + 1]
            let shareStr = bodies[i + 2]
            let pctStr = bodies[i + 3].trimmingCharacters(in: .whitespaces)
            if let code = firstMatch(in: name, pattern: #"#(\d{6})"#),
               let shares = Double(shareStr.replacingOccurrences(of: ",", with: "")),
               !pctStr.isEmpty
            {
                holdings[code] = Row(shares: shares, percent: pctStr)
            }
            i += 4
        }
        guard !holdings.isEmpty else { return nil }
        return ParsedList(date: dateStr.flatMap(parseDate),
                          dateLabel: dateStr ?? "",
                          holdings: holdings)
    }

    // MARK: - Rendering

    /// `4.69% 流通股 (5873万股, 截至 2026Q1)`. Shares use the 亿/万 buckets
    /// from `Formatting.bigShares`; the percent is passed through as-published
    /// (CCASS already rounds to 2 d.p.). The quarter label comes from the
    /// shareholding date so the figure is never read as daily.
    private func render(row: Row, date: Date) -> String {
        "\(row.percent) 流通股 (\(Formatting.bigShares(row.shares)), 截至 \(Self.quarterLabel(date)))"
    }

    /// `2026/03/31` → `2026Q1`. Buckets by calendar month (UTC, matching how
    /// the shareholding date is parsed).
    static func quarterLabel(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month], from: date)
        let q = ((c.month ?? 1) - 1) / 3 + 1
        return "\(c.year ?? 0)Q\(q)"
    }

    // MARK: - Helpers

    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy/MM/dd"
        return f.date(from: s)
    }

    private static func firstMatch(in s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s)
        else { return nil }
        return String(s[r])
    }

    private static func allMatches(in s: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(s.startIndex..., in: s)
        return re.matches(in: s, range: range).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s)
            else { return nil }
            return String(s[r])
        }
    }
}
