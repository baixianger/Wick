import Foundation

/// Free FINRA Equity Short Interest (空头持仓) fetcher for US-listed equities —
/// the published bi-monthly consolidated short-interest file every US exchange
/// reports into. A free, no-auth replacement for the paid short-interest feeds:
///
///   • shares short (`currentShortPositionQuantity`)
///   • change % vs prior settlement (`changePercent`)
///   • days-to-cover / 回补天数 (`daysToCoverQuantity`)
///   • average daily volume (`averageDailyVolumeQuantity`)
///   • reporting venue (`marketClassCode`: NYSE / NNM / NMS / OTC …)
///
/// Source: `POST https://api.finra.org/data/group/otcMarket/name/consolidatedShortInterest`
/// (public, no key). Foundation-only (the `TradingFloor` package builds on
/// Linux); a single POST per lookup — no rate limiter needed (FINRA is a normal
/// public API, queried at most once per ticker view).
///
/// The API's DEFAULT order returns OLDEST first, so we (a) constrain to a recent
/// `settlementDate` range (now − `years` → now) to bound the payload, and (b)
/// sort DESC client-side so the caller always gets newest-first. Cadence is
/// bi-monthly (mid-month + end-of-month) with a ~7–9 day publish lag, so a
/// 2-year window yields ~48 points.
///
/// US-only by construction (the file only covers US-listed issues); the tool /
/// UI gate on a bare US symbol before calling. Decoding is forgiving — fields
/// may be missing or arrive as strings — and the `daysToCoverQuantity == 999.99`
/// "non-computable" sentinel is mapped to `nil`. Best-effort throughout: any
/// failure returns `[]`, never throws.
public struct FINRAShortInterestProvider: Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// One settlement print for a ticker. `shortShares` is the consolidated
    /// short position (shares). `changePercent` / `daysToCover` / `adv` /
    /// `venue` are optional — missing or non-computable values degrade to nil.
    public struct ShortInterestPoint: Sendable {
        public let settlementDate: String   // "YYYY-MM-DD"
        public let shortShares: Double       // currentShortPositionQuantity
        public let changePercent: Double?    // vs previous settlement, %
        public let daysToCover: Double?       // 回补天数 (999.99 sentinel → nil)
        public let adv: Double?              // averageDailyVolumeQuantity
        public let venue: String?            // marketClassCode

        public init(settlementDate: String, shortShares: Double,
                    changePercent: Double?, daysToCover: Double?,
                    adv: Double?, venue: String?) {
            self.settlementDate = settlementDate
            self.shortShares = shortShares
            self.changePercent = changePercent
            self.daysToCover = daysToCover
            self.adv = adv
            self.venue = venue
        }
    }

    /// FINRA's "non-computable" days-to-cover sentinel — emitted when ADV is
    /// zero / unavailable. Treated as missing.
    private static let dtcSentinel = 999.99

    /// Trailing `years` of short-interest prints for a US ticker, NEWEST first.
    /// `[]` for an empty symbol or on any failure (best-effort). The symbol is
    /// uppercased before filtering.
    public func history(symbol: String, years: Int = 2) async -> [ShortInterestPoint] {
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !sym.isEmpty else { return [] }

        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let start = cal.date(byAdding: .year, value: -max(years, 1), to: now) ?? now
        let df = Self.dayFormatter
        let startStr = df.string(from: start)
        let endStr = df.string(from: now)

        let body = """
        {"compareFilters":[{"fieldName":"symbolCode","fieldValue":"\(sym)","compareType":"EQUAL"}],\
        "dateRangeFilters":[{"fieldName":"settlementDate","startDate":"\(startStr)","endDate":"\(endStr)"}],\
        "limit":1000}
        """

        guard let url = URL(string: "https://api.finra.org/data/group/otcMarket/name/consolidatedShortInterest") else {
            return []
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(body.utf8)

        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let rows = try? JSONDecoder().decode([Row].self, from: data)
        else { return [] }

        let points: [ShortInterestPoint] = rows.compactMap { r in
            guard let date = r.settlementDate, !date.isEmpty,
                  let shares = r.currentShortPositionQuantity?.value
            else { return nil }
            var dtc = r.daysToCoverQuantity?.value
            if let d = dtc, abs(d - Self.dtcSentinel) < 0.005 { dtc = nil }
            return ShortInterestPoint(
                settlementDate: String(date.prefix(10)),
                shortShares: shares,
                changePercent: r.changePercent?.value,
                daysToCover: dtc,
                adv: r.averageDailyVolumeQuantity?.value,
                venue: r.marketClassCode)
        }
        // Default order is oldest-first; sort DESC so newest is first.
        return points.sorted { $0.settlementDate > $1.settlementDate }
    }

    // MARK: - Date helper

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Wire type

    /// One row of the FINRA array. Numerics are `ForgivingDouble` so a value
    /// arriving as a JSON number, string, or `null` decodes cleanly.
    private struct Row: Decodable {
        let settlementDate: String?
        let currentShortPositionQuantity: ForgivingDouble?
        let changePercent: ForgivingDouble?
        let daysToCoverQuantity: ForgivingDouble?
        let averageDailyVolumeQuantity: ForgivingDouble?
        let marketClassCode: String?
    }
}
