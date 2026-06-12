import Foundation

/// Free Yahoo Finance `quoteSummary` fetcher — analyst ratings, target price,
/// recommendation, and the next earnings date. Yahoo's `v10/finance/quoteSummary`
/// endpoint rejects unauthenticated calls with `401 Invalid Crumb`, so this
/// provider performs the well-known cookie→crumb→quoteSummary handshake:
///
///   1. GET `https://fc.yahoo.com/` (browser UA) to receive an A1/A3 `Set-Cookie`.
///   2. GET `https://query1.finance.yahoo.com/v1/test/getcrumb` (same session) →
///      the crumb token (plain text).
///   3. GET `…/v10/finance/quoteSummary/{symbol}?modules=…&crumb={crumb}` →  JSON.
///
/// It owns a private `URLSession` with its own cookie store so the A1/A3 cookie
/// rides along automatically. Yahoo changes this flow periodically (and rate-
/// limits aggressively); every step degrades to `nil`, and the tool reports
/// 暂不可用 when the handshake fails. Foundation-only; decoding is forgiving so a
/// partial payload still yields whatever modules came back.
public struct YahooQuoteSummaryProvider: Sendable {
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = HTTPCookieStorage()
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: cfg)
    }

    private static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    /// Decoded analyst summary. All fields optional — Yahoo may omit modules.
    public struct YahooSummary: Sendable {
        public let symbol: String
        public let strongBuy: Int?
        public let buy: Int?
        public let hold: Int?
        public let sell: Int?
        public let strongSell: Int?
        public let targetMean: Double?
        public let currentPrice: Double?
        public let recommendationKey: String?   // e.g. "buy" / "hold"
        public let forwardPE: Double?
        public let nextEarningsDate: Date?

        public var totalAnalysts: Int? {
            let parts = [strongBuy, buy, hold, sell, strongSell].compactMap { $0 }
            return parts.isEmpty ? nil : parts.reduce(0, +)
        }
    }

    private func get(_ urlString: String) async -> (Data, HTTPURLResponse)? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("text/plain,*/*", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return nil }
        return (data, http)
    }

    /// Run the full handshake and return the parsed summary. `nil` if any step
    /// fails (rate-limit, crumb change, network). UPPERCASEs the symbol.
    public func summary(symbol: String) async -> YahooSummary? {
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !sym.isEmpty else { return nil }

        // Step 1: seed the cookie jar. fc.yahoo.com often 404s but still sets the
        // A1/A3 cookie; fall back to the finance landing page if needed.
        _ = await get("https://fc.yahoo.com/")
        if (session.configuration.httpCookieStorage?.cookies?.isEmpty ?? true) {
            _ = await get("https://finance.yahoo.com/")
        }

        // Step 2: crumb. A valid crumb is a short non-whitespace token; Yahoo's
        // throttle returns a sentence like "Too Many Requests" — reject those.
        guard let (crumbData, crumbResp) = await get("https://query1.finance.yahoo.com/v1/test/getcrumb"),
              crumbResp.statusCode == 200,
              let crumbRaw = String(data: crumbData, encoding: .utf8)
        else { return nil }
        let crumb = crumbRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !crumb.isEmpty, !crumb.contains(" "), crumb.count < 40 else { return nil }

        // Step 3: quoteSummary.
        let modules = "recommendationTrend,calendarEvents,financialData,defaultKeyStatistics"
        guard let escapedCrumb = crumb.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        let qsURL = "https://query1.finance.yahoo.com/v10/finance/quoteSummary/\(sym)"
            + "?modules=\(modules)&crumb=\(escapedCrumb)"
        guard let (data, resp) = await get(qsURL), resp.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Envelope.self, from: data),
              let result = decoded.quoteSummary?.result?.first
        else { return nil }

        let rt = result.recommendationTrend?.trend?.first
        let fin = result.financialData
        let stats = result.defaultKeyStatistics
        let earnings = result.calendarEvents?.earnings?.earningsDate?.first?.raw
        let nextEarnings = earnings.map { Date(timeIntervalSince1970: $0) }

        return YahooSummary(
            symbol: sym,
            strongBuy: rt?.strongBuy,
            buy: rt?.buy,
            hold: rt?.hold,
            sell: rt?.sell,
            strongSell: rt?.strongSell,
            targetMean: fin?.targetMeanPrice?.raw,
            currentPrice: fin?.currentPrice?.raw,
            recommendationKey: fin?.recommendationKey,
            forwardPE: stats?.forwardPE?.raw,
            nextEarningsDate: nextEarnings)
    }

    // MARK: - Wire types (forgiving)

    /// Yahoo wraps numbers as `{ "raw": 1.23, "fmt": "1.23" }` — sometimes the
    /// object is absent or `raw` is null. This decodes the `raw` leniently.
    private struct RawNumber: Decodable {
        let raw: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let d = try? c.decode(Double.self, forKey: .raw) { raw = d; return }
            // Occasionally a bare scalar; tolerate it.
            raw = nil
        }
        enum CodingKeys: String, CodingKey { case raw }
    }

    private struct Envelope: Decodable {
        let quoteSummary: QuoteSummary?
    }
    private struct QuoteSummary: Decodable {
        let result: [Result]?
    }
    private struct Result: Decodable {
        let recommendationTrend: RecommendationTrend?
        let calendarEvents: CalendarEvents?
        let financialData: FinancialData?
        let defaultKeyStatistics: DefaultKeyStatistics?
    }
    private struct RecommendationTrend: Decodable {
        let trend: [Trend]?
        struct Trend: Decodable {
            let strongBuy: Int?
            let buy: Int?
            let hold: Int?
            let sell: Int?
            let strongSell: Int?
        }
    }
    private struct CalendarEvents: Decodable {
        let earnings: Earnings?
        struct Earnings: Decodable {
            let earningsDate: [RawNumber]?
        }
    }
    private struct FinancialData: Decodable {
        let targetMeanPrice: RawNumber?
        let currentPrice: RawNumber?
        let recommendationKey: String?
    }
    private struct DefaultKeyStatistics: Decodable {
        let forwardPE: RawNumber?
    }
}
