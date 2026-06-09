import Foundation

/// One quote off Yahoo Finance's public v8 chart endpoint — last price,
/// previous close, and the derived day change. Shared by the context
/// decorators (`CrossAssetContextDecorator`, `OvernightContextDecorator`)
/// so the endpoint shape is parsed in exactly one place. No auth,
/// Foundation HTTP only, so it builds on Linux for WickServer.
struct YahooChartQuote: Sendable {
    let price: Double
    let previousClose: Double

    var dayChangePct: Double { (price / previousClose - 1) * 100 }

    /// Best-effort fetch: any transport / shape / status problem returns
    /// `nil` so basket callers can drop the leg rather than fail the line.
    static func fetch(symbol: String, session: URLSession) async -> YahooChartQuote? {
        var c = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)")!
        c.queryItems = [
            .init(name: "interval", value: "1d"),
            .init(name: "range", value: "1d"),
        ]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let chart = json["chart"] as? [String: Any],
              let result = (chart["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any]
        else { return nil }
        let price = (meta["regularMarketPrice"] as? Double)
            ?? (meta["regularMarketPrice"] as? Int).map(Double.init)
        let prev = (meta["chartPreviousClose"] as? Double)
            ?? (meta["chartPreviousClose"] as? Int).map(Double.init)
        guard let p = price, let pp = prev, pp != 0 else { return nil }
        return YahooChartQuote(price: p, previousClose: pp)
    }
}
