import Foundation

/// Always-on AgentTool surfacing free FINRA Equity Short Interest (空头持仓) for
/// US-listed equities — a free, no-key replacement for paid short-interest
/// feeds. Wicker calls it when a US ticker is in play; it returns a compact
/// summary of the latest settlement (shares short humanised, change % vs prior,
/// days-to-cover, ADV, venue) plus a short rising/falling trend note over the
/// recent prints.
///
/// US-only by construction (the FINRA file only covers US-listed issues). A
/// CN / HK / intl symbol (anything `CNSymbol.parse` recognises, or anything
/// carrying an exchange-suffix dot) gets a clean "仅美股" message rather than an
/// empty fetch. Best-effort: the provider returns `[]` on any failure, which we
/// render as a "无数据" line.
public struct ShortInterestTool: AgentTool {
    public let provider: FINRAShortInterestProvider
    public init(provider: FINRAShortInterestProvider) { self.provider = provider }

    public var spec: ToolSpec {
        ToolSpec(
            name: "us.short_interest",
            description: "US Equity Short Interest (空头持仓) from FINRA's free, "
                + "no-auth consolidated bi-monthly file. Returns the latest "
                + "settlement's shares short, change % vs the prior settlement, "
                + "days-to-cover (回补天数, a short-squeeze proxy), average daily "
                + "volume, reporting venue, and a short rising/falling trend over "
                + "recent prints. US-listed equities only (bare symbols like "
                + "AAPL / MSFT); not available for CN / HK / international tickers.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "symbol": { "type": "string", "description": "US-listed ticker, e.g. AAPL / MSFT / TSLA" }
              },
              "required": ["symbol"]
            }
            """)
    }

    private struct Args: Decodable { let symbol: String }

    public func call(arguments: Data) async throws -> String {
        let args = try JSONDecoder().decode(Args.self, from: arguments)
        let raw = args.symbol.trimmingCharacters(in: .whitespacesAndNewlines)

        // US-only gate: reject CN/HK (CNSymbol) and anything with an exchange
        // suffix dot (intl listings like VOD.L / BMW.DE).
        guard CNSymbol.parse(raw) == nil, !raw.contains(".") else {
            return "「\(raw)」无空头数据——FINRA 空头持仓仅覆盖美股（如 AAPL / MSFT / TSLA）。"
        }

        let sym = raw.uppercased()
        let points = await provider.history(symbol: sym, years: 2)
        guard let latest = points.first else {
            return "未获取到 \(sym) 的 FINRA 空头持仓数据（可能非美股、刚上市，或源暂不可用）。"
        }

        func shares(_ v: Double) -> String { Self.humanShares(v) }
        func signedPct(_ v: Double?) -> String { v.map { String(format: "%+.2f%%", $0) } ?? "—" }
        func dtc(_ v: Double?) -> String { v.map { String(format: "%.2f 天", $0) } ?? "—" }

        var lines = [
            "\(sym) 空头持仓 (FINRA) — 最新结算日 \(latest.settlementDate)",
            "做空股数 \(shares(latest.shortShares))（较上期 \(signedPct(latest.changePercent))）",
            "回补天数(days-to-cover) \(dtc(latest.daysToCover))"
                + (latest.adv.map { "；日均成交量 \(shares($0))" } ?? "")
                + (latest.venue.map { "；上报场所 \($0)" } ?? ""),
        ]

        // Trend over the recent prints (newest-first): compare latest vs the
        // print ~3 settlements back to characterise the short-interest drift.
        if points.count >= 3 {
            let window = Array(points.prefix(min(points.count, 6)))
            let oldest = window.last!
            let delta = latest.shortShares - oldest.shortShares
            let pct = oldest.shortShares > 0 ? delta / oldest.shortShares * 100 : 0
            let dir = delta > 0 ? "上升" : (delta < 0 ? "下降" : "持平")
            lines.append("近 \(window.count) 期空头\(dir)（\(oldest.settlementDate) "
                + "\(shares(oldest.shortShares)) → \(shares(latest.shortShares))，"
                + "\(String(format: "%+.1f%%", pct))）")
            let trend = window.reversed().map {
                "\($0.settlementDate.suffix(5)): \(shares($0.shortShares))"
            }.joined(separator: " | ")
            lines.append("逐期: \(trend)")
        }

        return ToolResultBounding.bound(lines.joined(separator: "\n"))
    }

    /// Humanise a share count to K / M / B with two significant places.
    static func humanShares(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1e9 { return String(format: "%.2fB", v / 1e9) }
        if a >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        if a >= 1e3 { return String(format: "%.1fK", v / 1e3) }
        return String(format: "%.0f", v)
    }
}

// MARK: - Convenience grouping

public enum ShortInterestTools {
    /// The single US short-interest tool, backed by one shared FINRA fetcher.
    public static func all(
        provider: FINRAShortInterestProvider = FINRAShortInterestProvider()
    ) -> [any AgentTool] {
        [ShortInterestTool(provider: provider)]
    }

    public static let names = ["us.short_interest"]
}
