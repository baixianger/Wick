import Foundation

/// One real news headline for the app's News / Overview tabs. Structured
/// (title + publisher + link + timestamp) rather than the flat `[String]`
/// the agent-side `EastMoneyNewsProvider` / `FinnhubNewsProvider` decorators
/// produce — the UI wants the source byline, an age label, and a tappable
/// link, so it carries the fields verbatim and lets the app map them into its
/// own `NewsItem`.
public struct NewsArticle: Sendable, Hashable {
    public let title: String
    public let summary: String?
    public let publisher: String?
    public let link: String?
    /// Publish time, when the source gives one (Yahoo: epoch seconds;
    /// EastMoney: `yyyy-MM-dd HH:mm:ss`). `nil` ⇒ unknown.
    public let published: Date?

    public init(title: String, summary: String?, publisher: String?,
                link: String?, published: Date?) {
        self.title = title
        self.summary = summary
        self.publisher = publisher
        self.link = link
        self.published = published
    }
}

/// Per-ticker REAL news fetcher for the GUI's News / Overview tabs — the live
/// replacement for `NewsFixtures`. Foundation-only (so it builds inside the
/// Linux-clean `TradingFloor` package); no API key.
///
/// Two free sources, routed by symbol exactly like `LiveDataStore` routes the
/// chart:
///
///   • CN A-share / HK (`CNSymbol.parse` succeeds) → 东方财富 (EastMoney)
///     `search-api-web` 个股资讯 — the same media feed the quote page's 资讯
///     tab renders (证券时报, 财联社, 界面新闻, …). This reuses the endpoint
///     `EastMoneyNewsProvider` already proves out for the agent snapshot, but
///     keeps the structured `url` / `date` / `mediaName` fields the UI needs.
///   • Everything else (US / international) → Yahoo Finance's keyless
///     `v1/finance/search` news feed (`newsCount=N`), which returns a `news`
///     array of ticker-relevant articles. (CandleKit's `YahooSearchAdapter`
///     hits the same endpoint but with `newsCount=0`, so it can't be reused
///     for news — hence this dedicated, news-only fetch.)
///
/// Best-effort throughout: any failure (throttle, empty, brand-new listing)
/// returns `[]` and the caller keeps showing the `NewsFixtures` fallback.
public struct StockNewsProvider: Sendable {
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

    /// Real per-ticker news, routed by symbol. CN/HK → EastMoney, else Yahoo.
    /// Returns `[]` (never throws) so the UI can fall through to fixtures.
    public func news(symbol: String, limit: Int = 20) async -> [NewsArticle] {
        if CNSymbol.parse(symbol) != nil {
            return await eastMoney(symbol: symbol, limit: limit)
        }
        return await yahoo(symbol: symbol, limit: limit)
    }

    // MARK: - Yahoo (US / international)

    /// Yahoo's keyless search endpoint carries a per-ticker `news` array.
    /// `quotesCount=0` keeps the payload to just the headlines we want.
    func yahoo(symbol: String, limit: Int) async -> [NewsArticle] {
        var c = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")!
        c.queryItems = [
            .init(name: "q", value: Self.yahooQuery(symbol)),
            .init(name: "newsCount", value: String(max(limit, 1))),
            .init(name: "quotesCount", value: "0"),
            .init(name: "lang", value: "en-US"),
            .init(name: "region", value: "US"),
        ]
        guard let url = c.url,
              let payload: YahooSearchPayload = await getJSON(url, referer: nil),
              let items = payload.news
        else { return [] }

        return items.compactMap { item in
            let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            return NewsArticle(
                title: title,
                summary: nil,                          // Yahoo search omits a body
                publisher: item.publisher,
                link: item.link,
                published: item.providerPublishTime.map { Date(timeIntervalSince1970: $0) })
        }
    }

    // MARK: - EastMoney (CN A-share / HK)

    /// 东方财富 `search-api-web` 个股资讯 — full-text article search keyed on the
    /// bare exchange code. Mirrors `EastMoneyNewsProvider.fetchArticles` but
    /// surfaces the structured `url` / `date` / `mediaName` the UI needs.
    func eastMoney(symbol: String, limit: Int) async -> [NewsArticle] {
        // Fold any user form (`SH600519`, `600519`, `0700.HK`, …) to canonical
        // first so `eastMoneySecid` resolves the bare exchange code the search
        // endpoint keys on.
        guard let canonical = CNSymbol.parse(symbol),
              let secid = CNSymbol.eastMoneySecid(canonical)
        else { return [] }
        let code = secid.split(separator: ".").last.map(String.init) ?? canonical

        let param: [String: Any] = [
            "uid": "",
            "keyword": code,
            "type": ["cmsArticleWebOld"],
            "client": "web",
            "clientType": "web",
            "clientVersion": "curr",
            "param": ["cmsArticleWebOld": [
                "searchScope": "default",
                "sort": "time",          // newest first
                "pageIndex": 1,
                "pageSize": max(limit, 1),
                "preTag": "",
                "postTag": "",
            ]],
        ]
        guard let paramData = try? JSONSerialization.data(withJSONObject: param),
              let paramString = String(data: paramData, encoding: .utf8)
        else { return [] }

        var c = URLComponents(string: "https://search-api-web.eastmoney.com/search/jsonp")!
        c.queryItems = [
            .init(name: "cb", value: ""),
            .init(name: "param", value: paramString),
        ]
        guard let url = c.url,
              let data = await getData(url, referer: "https://www.eastmoney.com/"),
              let json = Self.unwrapJSONP(data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let items = result["cmsArticleWebOld"] as? [[String: Any]]
        else { return [] }

        return items.compactMap { item in
            guard let title = (item["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else { return nil }
            // EastMoney wraps matched terms in <em> tags from the search index —
            // strip them so the headline reads clean in the UI.
            let cleanTitle = Self.stripTags(title)
            let content = (item["content"] as? String).map(Self.stripTags)
            return NewsArticle(
                title: cleanTitle,
                summary: (content?.isEmpty == false) ? content : nil,
                publisher: item["mediaName"] as? String,
                link: item["url"] as? String,
                published: (item["date"] as? String).flatMap(Self.parseEastMoneyDate))
        }
    }

    // MARK: - HTTP

    private func getData(_ url: URL, referer: String?) async -> Data? {
        await limiter.acquire(host: url.host ?? "")
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true
        else { return nil }
        return data
    }

    private func getJSON<T: Decodable>(_ url: URL, referer: String?) async -> T? {
        guard let data = await getData(url, referer: referer) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Helpers

    /// Map a ticker into the form Yahoo's search endpoint expects, mirroring
    /// the app-side `YahooSymbol.map` (not visible from this Linux-clean
    /// package): US class-share `.` → `-` (`BRK.B` → `BRK-B`), but a trailing
    /// known exchange suffix (`.L`, `.T`, …) is preserved verbatim. CN/HK
    /// symbols never reach here (routed to EastMoney upstream).
    private static func yahooQuery(_ id: String) -> String {
        if let dot = id.lastIndex(of: ".") {
            let suffix = String(id[id.index(after: dot)...]).uppercased()
            if exchangeSuffixes.contains(suffix) { return id }
        }
        return id.replacingOccurrences(of: ".", with: "-")
    }

    /// Yahoo exchange suffixes that must survive the `.`→`-` rewrite. Subset
    /// that matters for the news path; CN/HK (`SS`/`SZ`/`HK`) are included for
    /// completeness even though they're routed away before this runs.
    private static let exchangeSuffixes: Set<String> = [
        "SS", "SZ", "HK", "T", "L", "TO", "V", "PA", "DE", "F", "AS", "BR",
        "MI", "MC", "LS", "ST", "HE", "OL", "CO", "VI", "WA", "PR", "BK",
        "JK", "TW", "TWO", "SI", "KS", "KQ", "AX", "NS", "BO", "SA", "MX", "JO",
    ]

    /// `({…})` JSONP shell → parsed object; tolerates a bare body too.
    private static func unwrapJSONP(_ data: Data) -> Any? {
        if let direct = try? JSONSerialization.jsonObject(with: data) { return direct }
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.firstIndex(of: "("),
              let close = text.lastIndex(of: ")"), open < close else { return nil }
        let inner = String(text[text.index(after: open)..<close])
        return try? JSONSerialization.jsonObject(with: Data(inner.utf8))
    }

    /// Drop `<em>` / other inline tags EastMoney's search index injects around
    /// the matched query, leaving plain text.
    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "",
                               options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `"2026-06-12 20:42:00"` (Shanghai time) → `Date`.
    private static func parseEastMoneyDate(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: raw)
    }

    // MARK: - Wire types

    private struct YahooSearchPayload: Decodable {
        let news: [Item]?
        struct Item: Decodable {
            let title: String?
            let publisher: String?
            let link: String?
            let providerPublishTime: Double?
        }
    }
}
