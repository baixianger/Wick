import Foundation

/// Per-ticker data for Chinese A-shares (Shanghai / Shenzhen) and Hong Kong
/// stocks, sourced from EastMoney's open `push2his` + `push2` JSON endpoints
/// (the same APIs `akshare` wraps, called directly so we don't need a Python
/// runtime). Foundation-only — builds on Linux for WickServer.
///
/// Fills `lastPrice` + `priceSummary` + `technicals` via the shared
/// `Technicals` helper (same as `FMPMarketDataProvider`), plus a Chinese-keyed
/// `fundamentals` dictionary (市值 / PE / PB / 行业 / 52周高低 / 换手率).
/// News / 资金流 / 财报详情 are layered in as separate decorators.
///
/// Best-effort: a failed sub-fetch degrades that section rather than failing
/// the whole snapshot — same contract every provider in this package follows.
///
/// Non-CN symbols are NOT handled here; the router (`MarketRouter`) only
/// dispatches CN tickers to this provider. The provider does still guard
/// against accidental misuse and throws `EastMoneyError.notCNSymbol` so a
/// misconfigured chain fails loud instead of producing fake data.
public struct EastMoneyMarketDataProvider: MarketDataProvider {
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

    /// EastMoney K-line period — the `klt` query value. Mirrors the chart
    /// intervals the app's `LiveDataStore` exposes; there's no EastMoney
    /// equivalent of a 4-hour bar (same gap as Yahoo), so it's absent by
    /// design and the caller resamples or skips it.
    public enum KLinePeriod: Int, Sendable, CaseIterable {
        case m1  = 1
        case m5  = 5
        case m15 = 15
        case m30 = 30
        case h1  = 60
        case d1  = 101
        case w1  = 102
        case mo1 = 103

        /// Intraday periods carry a `"yyyy-MM-dd HH:mm"` date string in the
        /// `klines` rows; daily-and-coarser carry `"yyyy-MM-dd"`. The chart
        /// adapter picks its date formatter off this.
        public var isIntraday: Bool {
            switch self {
            case .m1, .m5, .m15, .m30, .h1: return true
            case .d1, .w1, .mo1:            return false
            }
        }
    }

    /// Raw bars for a CN ticker at the given period, ordered chronologically
    /// (oldest → newest). Backs both the MCP `wick.candles` tool (daily) and
    /// the app's chart UI (any period). For daily-and-coarser periods the
    /// `DailyBar.date` is `"yyyy-MM-dd"`; for intraday periods it's
    /// `"yyyy-MM-dd HH:mm"` (EastMoney's native row format).
    public func bars(symbol: String,
                     period: KLinePeriod = .d1,
                     limit: Int = 60) async throws -> [DailyBar]
    {
        guard let secid = CNSymbol.eastMoneySecid(symbol) else {
            throw EastMoneyError.notCNSymbol(symbol)
        }
        var c = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/kline/get")!
        c.queryItems = [
            .init(name: "secid", value: secid),
            .init(name: "klt", value: String(period.rawValue)),
            .init(name: "fqt", value: "1"),
            .init(name: "fields1", value: "f1,f2,f3,f4,f5,f6"),
            .init(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"),
            .init(name: "lmt", value: String(max(limit, 1))),
            .init(name: "end", value: "20500101"),
        ]
        guard let url = c.url,
              let payload: KLinePayload = await get(url),
              let klines = payload.data?.klines else { return [] }
        return klines.compactMap(parsePublicBar)
    }

    /// Raw daily bars for a CN ticker, ordered chronologically (oldest →
    /// newest). Used by the MCP `wick.candles` tool which surfaces the
    /// series back to its LLM caller — the workflow itself only needs the
    /// `priceSummary` / `technicals` strings the snapshot already carries.
    public func dailyBars(symbol: String, limit: Int = 60) async throws -> [DailyBar] {
        try await bars(symbol: symbol, period: .d1, limit: limit)
    }

    /// Single-row CSV → typed bar. Public-facing version that surfaces
    /// the full row (including volume + change) rather than the four
    /// floats `parseBar(_:)` keeps for technicals.
    private func parsePublicBar(_ row: String) -> DailyBar? {
        let p = row.split(separator: ",")
        guard p.count >= 11,
              let open  = Double(p[1]),
              let close = Double(p[2]),
              let high  = Double(p[3]),
              let low   = Double(p[4]),
              let vol   = Double(p[5]),
              let amt   = Double(p[6]),
              let pct   = Double(p[8])
        else { return nil }
        return DailyBar(date: String(p[0]),
                        open: open, close: close, high: high, low: low,
                        volume: vol, amount: amt, changePercent: pct)
    }

    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        guard let secid = CNSymbol.eastMoneySecid(symbol),
              let market = CNSymbol.market(symbol) else {
            throw EastMoneyError.notCNSymbol(symbol)
        }

        async let klineTask = fetchKLine(secid: secid)
        async let quoteTask = fetchQuote(secid: secid)
        let kline = await klineTask
        let quote = await quoteTask

        let closes = kline.map(\.close)
        let highs = kline.map(\.high)
        let lows = kline.map(\.low)
        let last = quote?.price ?? closes.last ?? 0

        var fundamentals: [String: String] = [:]
        if let q = quote {
            if let name = q.name { fundamentals["名称"] = name }
            if let industry = q.industry { fundamentals["行业"] = industry }
            if let cap = q.totalMarketCap { fundamentals["总市值"] = bigCNY(cap) }
            if let cap = q.freeFloatMarketCap { fundamentals["流通市值"] = bigCNY(cap) }
            if let pe = q.peTTM, pe > 0 { fundamentals["PE(TTM)"] = String(format: "%.1f", pe) }
            if let pb = q.pb, pb > 0 { fundamentals["PB"] = String(format: "%.2f", pb) }
            if let roe = q.roe { fundamentals["ROE"] = String(format: "%.1f%%", roe) }
            if let turnover = q.turnoverRate { fundamentals["换手率"] = String(format: "%.2f%%", turnover) }
            if let amount = q.amount { fundamentals["成交额"] = bigCNY(amount) }
        }
        if !highs.isEmpty, !lows.isEmpty, let hi = highs.max(), let lo = lows.min() {
            fundamentals["52周高低"] = String(format: "%.2f – %.2f", lo, hi)
        }
        fundamentals["市场"] = marketLabel(market)

        return MarketSnapshot(
            symbol: symbol,
            asOf: asOf,
            lastPrice: last == 0 ? nil : last,
            priceSummary: Technicals.priceSummary(closes: closes,
                                                  highs: highs,
                                                  lows: lows,
                                                  last: last),
            technicals: Technicals.technicalsSummary(closes: closes, last: last),
            fundamentals: fundamentals,
            news: []   // filled by EastMoneyNewsProvider decorator in a later phase
        )
    }

    // MARK: - K-line (push2his)

    /// Daily K-line, ~ 280 sessions back = roughly 13 months — enough for
    /// 200-SMA, 52-week range and the priceSummary 30-day delta.
    private func fetchKLine(secid: String) async -> [Bar] {
        var c = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/kline/get")!
        c.queryItems = [
            .init(name: "secid", value: secid),
            .init(name: "klt", value: "101"),         // daily
            .init(name: "fqt", value: "1"),           // forward-adjusted (qfq)
            .init(name: "fields1", value: "f1,f2,f3,f4,f5,f6"),
            // f51=date, f52=open, f53=close, f54=high, f55=low, f56=volume,
            // f57=amount, f58=amplitude, f59=pct_chg, f60=chg, f61=turnover
            .init(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"),
            .init(name: "lmt", value: "300"),
            .init(name: "end", value: "20500101"),
        ]
        guard let url = c.url else { return [] }
        guard let payload: KLinePayload = await get(url) else { return [] }
        guard let klines = payload.data?.klines else { return [] }
        return klines.compactMap(parseBar)
    }

    // MARK: - Quote + meta (push2 single-symbol get)

    private func fetchQuote(secid: String) async -> Quote? {
        // Field list is comma-separated; trailing fields safely ignored by the API.
        // f43=current, f57=code, f58=name, f60=prev_close, f71=turnover,
        // f84=total shares, f85=float shares, f116=total cap, f117=float cap,
        // f127=industry, f162=PE(TTM), f167=PB, f168=turnover today, f173=ROE
        let fields = "f43,f44,f45,f46,f47,f48,f57,f58,f60,f71,f84,f85,f116,f117,f127,f162,f167,f168,f173"
        // Use `push2delay` directly: `push2.eastmoney.com` 302-redirects all
        // open free-tier requests to `push2delay` with a protocol-relative
        // `Location: //push2delay…`, which Foundation's URLSession follows
        // inconsistently. Going to the delayed endpoint up front avoids the
        // redirect entirely and is also the honest behavior — the open
        // endpoints are delayed quotes, not realtime.
        var c = URLComponents(string: "https://push2delay.eastmoney.com/api/qt/stock/get")!
        c.queryItems = [
            .init(name: "secid", value: secid),
            .init(name: "fields", value: fields),
            .init(name: "invt", value: "2"),
            .init(name: "fltt", value: "2"),
        ]
        guard let url = c.url else { return nil }
        guard let payload: QuotePayload = await get(url) else { return nil }
        return payload.data.map { d in
            Quote(
                price: d.f43,
                name: d.f58,
                code: d.f57,
                amount: d.f48,
                industry: d.f127,
                totalMarketCap: d.f116,
                freeFloatMarketCap: d.f117,
                peTTM: d.f162,
                pb: d.f167,
                turnoverRate: d.f168,
                roe: d.f173
            )
        }
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ url: URL) async -> T? {
        await limiter.acquire(host: url.host ?? "")
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Parsing

    /// One CSV row from EastMoney's `klines` array. Layout matches the
    /// `fields2` we request:
    ///   date,open,close,high,low,volume,amount,amplitude,pct_chg,chg,turnover
    /// Failed rows are dropped silently — better to have a slightly shorter
    /// series than to fail the whole snapshot for one malformed line.
    private func parseBar(_ row: String) -> Bar? {
        let parts = row.split(separator: ",")
        guard parts.count >= 5,
              let open = Double(parts[1]),
              let close = Double(parts[2]),
              let high = Double(parts[3]),
              let low = Double(parts[4]) else { return nil }
        return Bar(open: open, close: close, high: high, low: low)
    }

    // MARK: - Formatting (CN conventions: 万 / 亿)

    /// Chinese big-number formatting. EastMoney returns CNY for A-shares and
    /// HKD for Hong Kong, but both display as 亿 / 万 in their native UIs, so
    /// we just use the same unit suffixes without a currency sigil — the LLM
    /// has the `市场` label to disambiguate.
    private func bigCNY(_ value: Double) -> String {
        let abs = Swift.abs(value)
        switch abs {
        case 1e12...: return String(format: "%.2f万亿", value / 1e12)
        case 1e8...:  return String(format: "%.2f亿", value / 1e8)
        case 1e4...:  return String(format: "%.1f万", value / 1e4)
        default:      return String(format: "%.0f", value)
        }
    }

    private func marketLabel(_ market: CNSymbol.Market) -> String {
        switch market {
        case .shanghai: return "沪市A股"
        case .shenzhen: return "深市A股"
        case .hongKong: return "港股"
        }
    }

    // MARK: - Wire types (only the fields we use)

    /// `https://push2his.eastmoney.com/api/qt/stock/kline/get` response shape.
    private struct KLinePayload: Decodable {
        let data: KLineData?
    }
    private struct KLineData: Decodable {
        let klines: [String]?
    }

    /// `https://push2.eastmoney.com/api/qt/stock/get` response shape. All
    /// numeric fields are optional — EastMoney returns `"-"` for missing
    /// values, which we route through a forgiving decoder below.
    private struct QuotePayload: Decodable {
        let data: QuoteFields?
    }
    private struct QuoteFields: Decodable {
        let f43: Double?    // current price
        let f44: Double?    // day high (unused for now)
        let f45: Double?    // day low (unused for now)
        let f46: Double?    // open (unused for now)
        let f47: Double?    // volume (unused for now)
        let f48: Double?    // amount today
        let f57: String?    // code
        let f58: String?    // name
        let f60: Double?    // prev close (unused for now)
        let f71: Double?    // turnover ratio (unused for now)
        let f84: Double?    // total shares (unused for now)
        let f85: Double?    // float shares (unused for now)
        let f116: Double?   // total market cap
        let f117: Double?   // free-float market cap
        let f127: String?   // industry
        let f162: Double?   // PE (TTM)
        let f167: Double?   // PB
        let f168: Double?   // turnover rate today (%)
        let f173: Double?   // ROE (%)

        // EastMoney returns `"-"` for missing numbers and a real number
        // otherwise. Default Decodable raises on `"-"`. This init swallows
        // the hyphen-as-double quirk per field by trying String first.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func d(_ key: CodingKeys) -> Double? {
                if let v = try? c.decodeIfPresent(Double.self, forKey: key) { return v }
                if let s = try? c.decodeIfPresent(String.self, forKey: key), s != "-" { return Double(s) }
                return nil
            }
            func s(_ key: CodingKeys) -> String? {
                let v = try? c.decodeIfPresent(String.self, forKey: key)
                return v?.isEmpty == true || v == "-" ? nil : v
            }
            f43 = d(.f43); f44 = d(.f44); f45 = d(.f45); f46 = d(.f46)
            f47 = d(.f47); f48 = d(.f48); f57 = s(.f57); f58 = s(.f58)
            f60 = d(.f60); f71 = d(.f71); f84 = d(.f84); f85 = d(.f85)
            f116 = d(.f116); f117 = d(.f117); f127 = s(.f127)
            f162 = d(.f162); f167 = d(.f167); f168 = d(.f168); f173 = d(.f173)
        }
        private enum CodingKeys: String, CodingKey {
            case f43, f44, f45, f46, f47, f48, f57, f58, f60, f71, f84, f85
            case f116, f117, f127, f162, f167, f168, f173
        }
    }

    private struct Bar {
        let open: Double; let close: Double; let high: Double; let low: Double
    }
    private struct Quote {
        let price: Double?
        let name: String?
        let code: String?
        let amount: Double?
        let industry: String?
        let totalMarketCap: Double?
        let freeFloatMarketCap: Double?
        let peTTM: Double?
        let pb: Double?
        let turnoverRate: Double?
        let roe: Double?
    }
}

public enum EastMoneyError: Error, Sendable, CustomStringConvertible {
    case notCNSymbol(String)

    public var description: String {
        switch self {
        case .notCNSymbol(let sym):
            return "EastMoneyMarketDataProvider received non-CN symbol '\(sym)' — routing is misconfigured."
        }
    }
}

/// One day's OHLCV plus change-percent. Public so the MCP `wick.candles`
/// tool can surface bars back to LLM callers without going through
/// `MarketSnapshot`. Kept separate from the private `Bar` struct used by
/// the technicals computation so that internal can stay minimal.
public struct DailyBar: Codable, Sendable, Hashable {
    public let date: String         // "yyyy-MM-dd"
    public let open: Double
    public let close: Double
    public let high: Double
    public let low: Double
    public let volume: Double
    public let amount: Double
    public let changePercent: Double
}
