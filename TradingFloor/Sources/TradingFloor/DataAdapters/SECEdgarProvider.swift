import Foundation

/// Free, official SEC EDGAR fetcher for US-listed issuers — no key required, but
/// SEC blocks default User-Agents, so every request carries a descriptive UA
/// (`Wick/1.0 (research; contact@impai.me)`) per their fair-access policy.
///
/// Two capabilities back two agent tools:
///
///   • `insiderFilings(symbol:limit:)` — recent **Form 4** (内部人交易) filings
///     from the issuer's submissions feed, best-effort enriched by parsing the
///     ownership XML (reporting owner, 买/卖 code, shares, price per share). If a
///     per-filing XML parse fails it degrades to a date/accession-only entry.
///   • `financials(symbol:)` — the key XBRL company-concept values (营收 / 净利 /
///     EPS / 总资产 / 股东权益), latest annual + most-recent value, with YoY where
///     two annual points are available.
///
/// Foundation-only (the package builds on Linux): a cached ticker→CIK map plus a
/// small number of HTTPS GETs per lookup. Best-effort throughout — `[]` / `nil`
/// on any failure, never throws. Symbols are uppercased; US-only by construction
/// (the tools gate CN / suffixed symbols and report 未找到 SEC 备案 on a missing CIK).
public struct SECEdgarProvider: Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// SEC fair-access User-Agent. SEC returns 403 for default / empty UAs.
    static let userAgent = "Wick/1.0 (research; contact@impai.me)"

    private func get(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true
        else { return nil }
        return data
    }

    // MARK: - Ticker → CIK

    /// Process-wide cache of the ticker→CIK map (the file is ~800 KB; fetch once).
    private actor CIKCache {
        static let shared = CIKCache()
        var map: [String: Int]?
        func get() -> [String: Int]? { map }
        func set(_ m: [String: Int]) { map = m }
    }

    /// Resolve a US ticker to its zero-padded 10-digit CIK string (`CIK0000320193`)
    /// plus the bare integer CIK (for the Archives path). `nil` if not found.
    func cik(for symbol: String) async -> (padded: String, intCIK: Int)? {
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !sym.isEmpty else { return nil }

        var map = await CIKCache.shared.get()
        if map == nil {
            guard let url = URL(string: "https://www.sec.gov/files/company_tickers.json"),
                  let data = await get(url),
                  let raw = try? JSONDecoder().decode([String: TickerEntry].self, from: data)
            else { return nil }
            var built: [String: Int] = [:]
            built.reserveCapacity(raw.count)
            for (_, e) in raw { built[e.ticker.uppercased()] = e.cik_str }
            await CIKCache.shared.set(built)
            map = built
        }
        guard let intCIK = map?[sym] else { return nil }
        return (String(format: "CIK%010d", intCIK), intCIK)
    }

    private struct TickerEntry: Decodable {
        let cik_str: Int
        let ticker: String
        let title: String
    }

    // MARK: - Insider (Form 4)

    /// One recent insider filing. `owner` / `title` / `netShares` / `avgPrice` are
    /// best-effort (parsed from the ownership XML); they degrade to nil when the
    /// XML is unavailable or unparseable. `netShares` is signed: + = net acquire
    /// (买), − = net dispose (卖) across the filing's non-derivative transactions.
    public struct InsiderFiling: Sendable {
        public let date: String          // filingDate "YYYY-MM-DD"
        public let accession: String     // e.g. 0001140361-26-023363
        public let owner: String?        // reporting person
        public let title: String?        // officer/director title
        public let netShares: Double?    // signed net non-derivative shares
        public let avgPrice: Double?     // share-weighted avg transaction price

        public init(date: String, accession: String, owner: String?,
                    title: String?, netShares: Double?, avgPrice: Double?) {
            self.date = date
            self.accession = accession
            self.owner = owner
            self.title = title
            self.netShares = netShares
            self.avgPrice = avgPrice
        }
    }

    /// Recent Form 4 filings for a US ticker, NEWEST first (up to `limit`). The
    /// most recent `min(limit, 2)` are enriched by parsing their ownership XML;
    /// the rest list date + accession only. `[]` on any failure / unknown CIK.
    public func insiderFilings(symbol: String, limit: Int = 5) async -> [InsiderFiling] {
        guard let (padded, intCIK) = await cik(for: symbol),
              let url = URL(string: "https://data.sec.gov/submissions/\(padded).json"),
              let data = await get(url),
              let sub = try? JSONDecoder().decode(Submissions.self, from: data)
        else { return [] }

        let r = sub.filings.recent
        let count = min(r.form.count, r.filingDate.count, r.accessionNumber.count, r.primaryDocument.count)
        var out: [InsiderFiling] = []
        var enriched = 0
        let enrichBudget = min(max(limit, 1), 2)

        var i = 0
        while i < count, out.count < max(limit, 1) {
            defer { i += 1 }
            guard r.form[i] == "4" else { continue }
            let date = String(r.filingDate[i].prefix(10))
            let accession = r.accessionNumber[i]
            let primary = r.primaryDocument[i]

            var owner: String?
            var title: String?
            var net: Double?
            var price: Double?

            if enriched < enrichBudget {
                enriched += 1
                if let parsed = await parseForm4(intCIK: intCIK, accession: accession, primaryDocument: primary) {
                    owner = parsed.owner
                    title = parsed.title
                    net = parsed.netShares
                    price = parsed.avgPrice
                }
            }
            out.append(InsiderFiling(date: date, accession: accession,
                                     owner: owner, title: title,
                                     netShares: net, avgPrice: price))
        }
        return out
    }

    /// Fetch + parse the raw Form 4 ownership XML. The submissions feed's
    /// `primaryDocument` is the XSL-rendered HTML (`xslF345X06/form4.xml`); the
    /// raw XML lives at the same directory with the `xslF345X06/` prefix dropped.
    private func parseForm4(intCIK: Int, accession: String, primaryDocument: String) async -> Form4? {
        let accNoDashes = accession.replacingOccurrences(of: "-", with: "")
        // Strip any xsl folder prefix to reach the raw XML filename.
        let rawDoc = primaryDocument.components(separatedBy: "/").last ?? primaryDocument
        guard rawDoc.lowercased().hasSuffix(".xml"),
              let url = URL(string: "https://www.sec.gov/Archives/edgar/data/\(intCIK)/\(accNoDashes)/\(rawDoc)"),
              let data = await get(url)
        else { return nil }

        let parser = Form4Parser()
        return parser.parse(data)
    }

    fileprivate struct Form4: Sendable {
        let owner: String?
        let title: String?
        let netShares: Double?
        let avgPrice: Double?
    }

    // MARK: - Financials (XBRL company-concept)

    /// One financial metric resolved from XBRL. `latest` is the most recent value
    /// of any period; `annual` is the most recent FY (10-K) value; `priorAnnual`
    /// is the FY one year before that (for YoY). Any may be nil.
    public struct FinancialMetric: Sendable {
        public let label: String         // Chinese label
        public let unit: String          // "USD" / "USD/shares" / "shares"
        public let latest: Point?
        public let annual: Point?
        public let priorAnnual: Point?

        public struct Point: Sendable {
            public let end: String       // period end "YYYY-MM-DD"
            public let value: Double
            public let form: String      // 10-K / 10-Q
        }

        public init(label: String, unit: String, latest: Point?, annual: Point?, priorAnnual: Point?) {
            self.label = label
            self.unit = unit
            self.latest = latest
            self.annual = annual
            self.priorAnnual = priorAnnual
        }

        /// YoY % from the two most recent annual points, when both exist and the
        /// base is non-zero.
        public var annualYoY: Double? {
            guard let a = annual?.value, let p = priorAnnual?.value, p != 0 else { return nil }
            return (a - p) / abs(p) * 100
        }
    }

    /// XBRL concepts pulled, in display order. Revenue has a fallback tag.
    private static let concepts: [(label: String, unit: String, tags: [String])] = [
        ("营收 Revenue", "USD", ["RevenueFromContractWithCustomerExcludingAssessedTax", "Revenues"]),
        ("净利润 Net income", "USD", ["NetIncomeLoss"]),
        ("每股收益 EPS(基本)", "USD/shares", ["EarningsPerShareBasic"]),
        ("总资产 Assets", "USD", ["Assets"]),
        ("股东权益 Equity", "USD", ["StockholdersEquity"]),
    ]

    /// Key XBRL financials for a US ticker. `[]` on unknown CIK / total failure;
    /// individual metrics with no data are omitted.
    public func financials(symbol: String) async -> [FinancialMetric] {
        guard let (padded, _) = await cik(for: symbol) else { return [] }

        var out: [FinancialMetric] = []
        for concept in Self.concepts {
            var metric: FinancialMetric?
            for tag in concept.tags {
                if let m = await fetchConcept(padded: padded, tag: tag,
                                              label: concept.label, unit: concept.unit) {
                    metric = m
                    break
                }
            }
            if let m = metric { out.append(m) }
        }
        return out
    }

    private func fetchConcept(padded: String, tag: String, label: String, unit: String) async -> FinancialMetric? {
        guard let url = URL(string: "https://data.sec.gov/api/xbrl/companyconcept/\(padded)/us-gaap/\(tag).json"),
              let data = await get(url),
              let concept = try? JSONDecoder().decode(XBRLConcept.self, from: data)
        else { return nil }

        // Pick the units array: prefer USD, else shares, else first available.
        let unitKey = concept.units.keys.contains("USD") ? "USD"
            : (concept.units.keys.contains("shares") ? "shares" : concept.units.keys.first)
        guard let key = unitKey, let rows = concept.units[key], !rows.isEmpty else { return nil }

        // Latest by period end across all forms.
        let latestRow = rows.max { ($0.end ?? "") < ($1.end ?? "") }
        // Annual (FY) points: prefer fp == "FY" or form 10-K, sorted by end DESC.
        let annuals = rows.filter { ($0.fp == "FY") || ($0.form == "10-K") }
            .sorted { ($0.end ?? "") > ($1.end ?? "") }

        func point(_ r: XBRLRow?) -> FinancialMetric.Point? {
            guard let r, let end = r.end else { return nil }
            return FinancialMetric.Point(end: end, value: r.val, form: r.form ?? "—")
        }

        let latest = point(latestRow)
        let annual = point(annuals.first)
        // Prior FY: first annual whose end-year differs from `annual`'s end-year.
        var prior: XBRLRow?
        if let annualEnd = annuals.first?.end {
            let annualYear = String(annualEnd.prefix(4))
            prior = annuals.first { ($0.end.map { String($0.prefix(4)) } ?? "") != annualYear }
        }
        let priorAnnual = point(prior)

        guard latest != nil || annual != nil else { return nil }
        return FinancialMetric(label: label, unit: unit,
                               latest: latest, annual: annual, priorAnnual: priorAnnual)
    }

    // MARK: - Wire types

    private struct Submissions: Decodable {
        let filings: Filings
        struct Filings: Decodable { let recent: Recent }
        struct Recent: Decodable {
            let form: [String]
            let filingDate: [String]
            let accessionNumber: [String]
            let primaryDocument: [String]
        }
    }

    private struct XBRLConcept: Decodable {
        let units: [String: [XBRLRow]]
    }
    private struct XBRLRow: Decodable {
        let end: String?
        let val: Double
        let fy: Int?
        let fp: String?
        let form: String?
    }
}

// MARK: - Form 4 XML parsing

/// Minimal XMLParser-driven reader for SEC Form 4 ownership XML. Captures the
/// reporting owner name + title and the non-derivative transactions' shares /
/// acquired-or-disposed code (A/D) / price-per-share, then nets them into a
/// signed share total and a share-weighted average price.
private final class Form4Parser: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var text = ""

    private var owner: String?
    private var title: String?

    // Per-transaction scratch (the value lives inside a nested <value> element).
    private var inNonDeriv = false
    private var curShares: Double?
    private var curCode: String?      // "A" or "D"
    private var curPrice: Double?

    private var netShares: Double = 0
    private var sawTxn = false
    private var priceWeightSum: Double = 0   // Σ |shares|·price
    private var priceSharesSum: Double = 0   // Σ |shares| (for txns with a price)

    func parse(_ data: Data) -> SECEdgarProvider.Form4? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        let net: Double? = sawTxn ? netShares : nil
        let avg: Double? = priceSharesSum > 0 ? priceWeightSum / priceSharesSum : nil
        return SECEdgarProvider.Form4(
            owner: owner?.isEmpty == false ? owner : nil,
            title: title?.isEmpty == false ? title : nil,
            netShares: net,
            avgPrice: avg)
    }

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        path.append(name)
        text = ""
        if name == "nonDerivativeTransaction" {
            inNonDeriv = true
            curShares = nil; curCode = nil; curPrice = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "rptOwnerName":
            if owner == nil, !trimmed.isEmpty { owner = trimmed }
        case "officerTitle":
            if title == nil, !trimmed.isEmpty { title = trimmed }
        case "value" where inNonDeriv:
            // The enclosing element (one level up) tells us which field this is.
            if path.count >= 3 {
                let field = path[path.count - 2]
                switch field {
                case "transactionShares": curShares = Double(trimmed)
                case "transactionAcquiredDisposedCode": curCode = trimmed
                case "transactionPricePerShare": curPrice = Double(trimmed)
                default: break
                }
            }
        case "nonDerivativeTransaction":
            inNonDeriv = false
            if let sh = curShares {
                sawTxn = true
                let signed = (curCode == "D") ? -sh : sh
                netShares += signed
                if let p = curPrice, p > 0 {
                    priceWeightSum += abs(sh) * p
                    priceSharesSum += abs(sh)
                }
            }
        default:
            break
        }

        text = ""
        if !path.isEmpty { path.removeLast() }
    }
}
