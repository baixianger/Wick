import Foundation

/// Appends a 所属板块 line to the snapshot's `macro` for CN/HK tickers —
/// the stock's own industry board plus its leading concept/theme boards,
/// each with the day's move:
///
///   所属板块 食品饮料 -0.2%; 白酒Ⅲ -2.4%; 贵州板块 +1.5%; 酿酒概念 -1.6%
///
/// This is the per-stock half of the sector picture the broad-market
/// `SectorContextDecorator` deliberately deferred: A-share moves are
///板块-driven (the theme rotates, every member moves together), so "is
/// today's move the stock or its board?" is a first-order analyst
/// question. Source: EastMoney `push2delay …/qt/slist/get` with `spt=3`
/// — the quote page's 所属板块 tab — which returns the boards a stock
/// belongs to directly, so no static BKxxxx mapping table is needed
/// (the reason this was deferred originally).
///
/// The raw list mixes real signal with index-membership noise (融资融券,
/// HS300_, 机构重仓 …); a small denylist plus the trailing-underscore
/// convention filters those, and near-duplicate tiers (白酒Ⅱ / 白酒Ⅲ)
/// are deduped by their stem. Works for both A-shares (BKxxxx boards)
/// and HK (HKxxxx boards). Per-symbol-per-day cache, best-effort.
public actor BoardContextDecorator: MarketDataProvider {
    private let base: any MarketDataProvider
    private let session: URLSession
    private let limiter: HTTPRateLimiter
    private var cache: [String: String] = [:]   // "symbol|day" → line

    /// Membership flags that say nothing about the stock's theme.
    private static let denylist: Set<String> = [
        "融资融券", "机构重仓", "转融券标的", "沪股通", "深股通", "港股通",
        "证金持股", "标普道琼斯", "MSCI中国", "富时罗素", "AH股", "股份回购",
        "B股", "GDR",
    ]

    /// At most this many boards on the line — industry first, then the
    /// strongest-signal themes in EastMoney's own ordering.
    private let maxBoards = 4

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
        guard let secid = CNSymbol.eastMoneySecid(snap.symbol) else { return snap }

        let key = "\(snap.symbol)|\(TradingDay.key(asOf))"
        let line: String
        if let cached = cache[key] {
            line = cached
        } else {
            line = await boardLine(secid: secid)
            if !line.isEmpty { cache[key] = line }
        }
        if !line.isEmpty {
            snap.macro = snap.macro.isEmpty ? line : snap.macro + "\n" + line
        }
        return snap
    }

    private func boardLine(secid: String) async -> String {
        var c = URLComponents(string: "https://push2delay.eastmoney.com/api/qt/slist/get")!
        c.queryItems = [
            .init(name: "secid", value: secid),
            .init(name: "spt", value: "3"),
            .init(name: "fltt", value: "2"),
            .init(name: "invt", value: "2"),
            .init(name: "fields", value: "f12,f13,f14,f3"),
            .init(name: "ut", value: "fa5fd1943c7b386f172d6893dbfba10b"),
            .init(name: "pi", value: "0"),
            .init(name: "pz", value: "30"),
            .init(name: "po", value: "1"),
            .init(name: "np", value: "1"),
        ]
        guard let url = c.url else { return "" }
        await limiter.acquire(host: url.host ?? "")
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let diff = payload["diff"] as? [[String: Any]]
        else { return "" }

        var parts: [String] = []
        var seenStems: Set<String> = []
        for item in diff {
            guard parts.count < maxBoards,
                  let name = item["f14"] as? String,
                  let pct = item["f3"] as? Double
            else { continue }
            guard !name.hasSuffix("_"), !Self.denylist.contains(name) else { continue }
            let stem = Self.stem(name)
            guard seenStems.insert(stem).inserted else { continue }
            parts.append("\(name) \(String(format: "%+.1f%%", pct))")
        }
        guard !parts.isEmpty else { return "" }
        return "所属板块 " + parts.joined(separator: "; ")
    }

    /// `白酒Ⅲ` → `白酒`, so tiered industry levels collapse to one entry.
    private static func stem(_ name: String) -> String {
        var s = name
        while let last = s.last, "ⅠⅡⅢⅣ".contains(last) { s.removeLast() }
        return s
    }
}
