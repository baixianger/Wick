import Foundation

/// Fills `news` for Chinese A-share / Hong Kong tickers from two open
/// EastMoney endpoints (no key, Foundation HTTP, Linux-safe):
///
///   • 个股资讯 — `search-api-web.eastmoney.com` full-text article search
///     keyed on the stock code, the same feed the quote page's 资讯 tab
///     renders. Gives media headlines (证券时报, 人民财讯, …).
///   • 公司公告 — `np-anotice-stock.eastmoney.com/api/security/ann`, the
///     exchange-filing stream (财报披露, 股东大会, 回购, 减持, …).
///
/// This was the open `news: []` placeholder in
/// `EastMoneyMarketDataProvider` — without it the sentiment and news
/// analysts saw "No recent news available" for every CN ticker. The two
/// streams are deliberately mixed: media coverage carries the narrative,
/// filings carry the facts, and the analyst prompt benefits from seeing
/// both with their dates.
///
/// Decorator contract matches `FinnhubNewsProvider`: only fills when the
/// base left `news` empty, and only for `CNSymbol` tickers — so the two
/// news decorators can stack in either order without fighting.
///
/// Best-effort: either sub-fetch failing just drops that stream; both
/// failing leaves `news` empty (the analyst handles that today already).
/// Per-symbol-per-day cache.
public actor EastMoneyNewsProvider: MarketDataProvider {
    private let base: any MarketDataProvider
    private let session: URLSession
    private let limiter: HTTPRateLimiter
    private var cache: [String: [String]] = [:]   // "symbol|day" → lines

    /// How many media headlines / filings to surface. Headlines carry
    /// more analyst signal per line, filings are deduped by the exchange.
    private let maxArticles = 6
    private let maxAnnouncements = 4

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
        guard snap.news.isEmpty,
              let market = CNSymbol.market(snap.symbol) else { return snap }

        let key = "\(snap.symbol)|\(TradingDay.key(asOf))"
        if let lines = cache[key] {
            snap.news = lines
            return snap
        }

        let code = Self.queryCode(symbol: snap.symbol, market: market)
        async let articlesTask = fetchArticles(code: code)
        async let filingsTask = fetchAnnouncements(code: code, market: market)
        let (articles, filings) = await (articlesTask, filingsTask)

        let lines = articles + filings
        if !lines.isEmpty { cache[key] = lines }
        snap.news = lines
        return snap
    }

    /// Both endpoints want the bare exchange code — 6-digit for A-shares,
    /// 5-digit zero-padded for HK (the secid form minus the market prefix).
    private static func queryCode(symbol: String, market: CNSymbol.Market) -> String {
        let secid = CNSymbol.eastMoneySecid(symbol) ?? ""
        return secid.split(separator: ".").last.map(String.init) ?? symbol
    }

    // MARK: - 个股资讯 (media articles)

    private func fetchArticles(code: String) async -> [String] {
        let param: [String: Any] = [
            "uid": "",
            "keyword": code,
            "type": ["cmsArticleWebOld"],
            "client": "web",
            "clientType": "web",
            "clientVersion": "curr",
            "param": ["cmsArticleWebOld": [
                "searchScope": "default",
                "sort": "time",          // newest first — "default" is relevance
                "pageIndex": 1,
                "pageSize": maxArticles,
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
        guard let url = c.url, let data = await get(url) else { return [] }

        // `cb=` still wraps the JSON in `( … )` — strip the JSONP shell.
        guard let json = Self.unwrapJSONP(data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let items = result["cmsArticleWebOld"] as? [[String: Any]]
        else { return [] }

        return items.compactMap { item in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            let date = (item["date"] as? String).map(Self.shortDate) ?? ""
            let media = (item["mediaName"] as? String).map { " — \($0)" } ?? ""
            return "[\(date)] \(title)\(media)"
        }
    }

    // MARK: - 公司公告 (exchange filings)

    private func fetchAnnouncements(code: String, market: CNSymbol.Market) async -> [String] {
        var c = URLComponents(string: "https://np-anotice-stock.eastmoney.com/api/security/ann")!
        c.queryItems = [
            .init(name: "sr", value: "-1"),
            .init(name: "page_size", value: String(maxAnnouncements)),
            .init(name: "page_index", value: "1"),
            .init(name: "ann_type", value: market == .hongKong ? "H" : "A"),
            .init(name: "stock_list", value: code),
        ]
        guard let url = c.url, let data = await get(url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let items = payload["list"] as? [[String: Any]]
        else { return [] }

        return items.compactMap { item in
            let title = (item["title_ch"] as? String) ?? (item["title"] as? String) ?? ""
            guard !title.isEmpty else { return nil }
            let date = (item["notice_date"] as? String).map(Self.shortDate) ?? ""
            return "[公告 \(date)] \(title)"
        }
    }

    // MARK: - Plumbing

    private func get(_ url: URL) async -> Data? {
        await limiter.acquire(host: url.host ?? "")
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.eastmoney.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true
        else { return nil }
        return data
    }

    /// `({"code":0,…})` → parsed JSON object. Tolerates a bare (non-wrapped)
    /// body too, in case the endpoint drops the JSONP shell for `cb=`.
    private static func unwrapJSONP(_ data: Data) -> Any? {
        if let direct = try? JSONSerialization.jsonObject(with: data) { return direct }
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.firstIndex(of: "("),
              let close = text.lastIndex(of: ")"), open < close else { return nil }
        let inner = String(text[text.index(after: open)..<close])
        return try? JSONSerialization.jsonObject(with: Data(inner.utf8))
    }

    /// `"2026-06-03 11:01:00"` → `"06-03"`. The year is noise inside a
    /// same-week news list; the analyst gets `asOf` in the context header.
    private static func shortDate(_ raw: String) -> String {
        let datePart = raw.split(separator: " ").first.map(String.init) ?? raw
        let comps = datePart.split(separator: "-")
        guard comps.count == 3 else { return datePart }
        return "\(comps[1])-\(comps[2])"
    }
}
