import Foundation

/// Adds a one-line broad-market index reading to the snapshot's `macro`
/// field — "how is the index this ticker belongs to behaving today vs
/// its 52-week high?" — so the LLM can frame the stock's move against
/// market regime instead of evaluating it in isolation.
///
/// Routing:
///   - A-shares (`.SS` / `.SZ`) → 沪深 300 (CSI 300)
///   - Hong Kong (`.HK`)        → 恒生指数 (HSI)
///   - everything else          → S&P 500 (SPX)
///
/// Per-day cache: each index is fetched once per trading day per
/// process. Intraday moves don't change the analyst's framing enough
/// to justify per-call fetches; report cache amortises the rest.
///
/// Per-stock sector / industry indices were on the original plan but
/// the EastMoney board-code (BKxxxx) ↔ industry-name mapping is messy
/// (500+ BK codes, overlapping names like "白酒Ⅱ" / "白酒"). Deferred
/// to a v2 sector decorator with a curated mapping table.
public actor SectorContextDecorator: MarketDataProvider {
    private let base: any MarketDataProvider
    private let session: URLSession
    private var cache: [String: (day: String, line: String)] = [:]

    public init(base: any MarketDataProvider,
                session: URLSession = .shared)
    {
        self.base = base
        self.session = session
    }

    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        var snap = try await base.snapshot(symbol: symbol, asOf: asOf)
        let key = indexSecid(for: symbol)
        let line = await fetchLine(secid: key.secid, label: key.label, asOf: asOf)
        if !line.isEmpty {
            snap.macro = snap.macro.isEmpty ? line : snap.macro + "\n" + line
        }
        return snap
    }

    // MARK: - Routing

    private struct IndexKey {
        let secid: String
        let label: String
    }

    private func indexSecid(for symbol: String) -> IndexKey {
        switch CNSymbol.market(symbol) {
        case .shanghai, .shenzhen:
            return IndexKey(secid: "1.000300", label: "沪深300")
        case .hongKong:
            return IndexKey(secid: "100.HSI", label: "恒生指数")
        case .none:
            // Non-CN tickers — default to SPX. International suffixes
            // (.T / .L) get S&P too; not perfect but the simplest
            // "global market regime" proxy without a per-country table.
            return IndexKey(secid: "100.SPX", label: "标普500")
        }
    }

    // MARK: - Fetch + render

    private func fetchLine(secid: String, label: String, asOf: Date) async -> String {
        let day = TradingDay.key(asOf)
        if let cached = cache[secid], cached.day == day { return cached.line }
        guard let snap = await fetchIndex(secid: secid) else { return "" }
        let line = render(label: label, snap: snap)
        if !line.isEmpty { cache[secid] = (day, line) }
        return line
    }

    private func fetchIndex(secid: String) async -> IndexQuote? {
        // Use push2delay for free-tier-friendly behaviour (see the note in
        // EastMoneyMarketDataProvider — push2 redirects to push2delay
        // anyway, and URLSession doesn't always follow that protocol-
        // relative `Location` cleanly).
        var c = URLComponents(string: "https://push2delay.eastmoney.com/api/qt/stock/get")!
        c.queryItems = [
            .init(name: "secid", value: secid),
            // f43=current, f58=name, f60=prev_close, f170=day-change%,
            // f171=% from 52w high
            .init(name: "fields", value: "f43,f58,f60,f170,f171"),
            .init(name: "invt", value: "2"),
            .init(name: "fltt", value: "2"),
        ]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = json["data"] as? [String: Any]
        else { return nil }
        return IndexQuote(
            price: (d["f43"] as? Double),
            name: (d["f58"] as? String),
            dayChangePct: (d["f170"] as? Double),
            fromHighPct: (d["f171"] as? Double)
        )
    }

    private func render(label: String, snap: IndexQuote) -> String {
        var parts: [String] = []
        let display = snap.name ?? label
        if let p = snap.price { parts.append(String(format: "%.2f", p)) }
        if let dc = snap.dayChangePct {
            parts.append(String(format: "%+.2f%% today", dc))
        }
        if let hi = snap.fromHighPct {
            // EastMoney's f171 is the percent the current price sits
            // BELOW the 52-week high — already positive, but render as
            // signed so the LLM sees direction at a glance.
            parts.append(String(format: "-%.2f%% from 52w high", hi))
        }
        guard !parts.isEmpty else { return "" }
        return "市场指数 \(display) \(parts.joined(separator: ", "))"
    }

    private struct IndexQuote {
        let price: Double?
        let name: String?
        let dayChangePct: Double?
        let fromHighPct: Double?
    }
}
