import Foundation

/// Two always-on AgentTools surfacing free, official SEC EDGAR data for US-listed
/// issuers — no key, descriptive-UA-only:
///
///   • `us.insider`     内部人交易 — recent Form 4 filings (who / 买卖 / shares / price)
///                       + a net buy/sell tilt across the recent filings.
///   • `us.financials`  XBRL 财务 — latest 营收 / 净利 / EPS / 总资产 / 股东权益, with
///                       the report period + YoY where computable.
///
/// Both are US-only by construction (SEC covers US-registered issuers): a CN / HK
/// symbol (anything `CNSymbol.parse` recognises, or anything carrying an
/// exchange-suffix dot) gets a clean message, and an unknown CIK yields
/// 未找到 SEC 备案. Best-effort: the provider returns `[]` on failure → 无数据.

// MARK: - Shared US-only gate + formatting

private func usGateFailureMessage(_ symbol: String) -> String {
    "「\(symbol)」无 SEC 数据——该工具仅支持美股上市公司（如 AAPL / MSFT / NVDA）。"
}

/// True when `raw` is a bare US ticker (not CN/HK, no exchange-suffix dot).
private func isUSSymbol(_ raw: String) -> Bool {
    CNSymbol.parse(raw) == nil && !raw.contains(".")
}

/// Humanise a USD amount to B / M / K (signed).
private func humanUSD(_ v: Double) -> String {
    let a = abs(v)
    if a >= 1e9 { return String(format: "$%.2fB", v / 1e9) }
    if a >= 1e6 { return String(format: "$%.1fM", v / 1e6) }
    if a >= 1e3 { return String(format: "$%.1fK", v / 1e3) }
    return String(format: "$%.2f", v)
}

private func humanShares(_ v: Double) -> String {
    let a = abs(v)
    let sign = v < 0 ? "-" : ""
    if a >= 1e9 { return String(format: "%@%.2fB", sign, a / 1e9) }
    if a >= 1e6 { return String(format: "%@%.1fM", sign, a / 1e6) }
    if a >= 1e3 { return String(format: "%@%.1fK", sign, a / 1e3) }
    return String(format: "%@%.0f", sign, a)
}

// MARK: - 1) 内部人交易 us.insider

public struct InsiderTool: AgentTool {
    public let provider: SECEdgarProvider
    public init(provider: SECEdgarProvider) { self.provider = provider }

    public var spec: ToolSpec {
        ToolSpec(
            name: "us.insider",
            description: "US insider trading (内部人交易) from SEC EDGAR's free, "
                + "official Form 4 filings. Returns the recent filings — reporting "
                + "person, date, 买/卖 (acquire/dispose), shares, and price — plus a "
                + "net buy/sell tilt across them. US-listed issuers only (bare "
                + "symbols like AAPL / MSFT); not CN / HK / international tickers.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "symbol": { "type": "string", "description": "US-listed ticker, e.g. AAPL / MSFT / NVDA" }
              },
              "required": ["symbol"]
            }
            """)
    }

    private struct Args: Decodable { let symbol: String }

    public func call(arguments: Data) async throws -> String {
        let args = try JSONDecoder().decode(Args.self, from: arguments)
        let raw = args.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUSSymbol(raw) else { return usGateFailureMessage(raw) }
        let sym = raw.uppercased()

        guard await provider.cik(for: sym) != nil else {
            return "未找到 \(sym) 的 SEC 备案（可能非美股或代码有误）。"
        }
        let filings = await provider.insiderFilings(symbol: sym, limit: 6)
        guard !filings.isEmpty else {
            return "\(sym)：SEC 未返回近期 Form 4（内部人交易）备案。"
        }

        var lines = ["\(sym) 内部人交易 (SEC Form 4) — 近 \(filings.count) 笔备案"]
        var netAcquire = 0.0
        var netDispose = 0.0
        var tallied = false

        for f in filings {
            var parts = ["• \(f.date)"]
            if let o = f.owner {
                parts.append(f.title.map { "\(o)（\($0)）" } ?? o)
            }
            if let n = f.netShares {
                tallied = true
                if n >= 0 { netAcquire += n } else { netDispose += -n }
                let side = n >= 0 ? "买" : "卖"
                parts.append("\(side) \(humanShares(abs(n))) 股")
                if let p = f.avgPrice { parts.append("@ $\(String(format: "%.2f", p))") }
            } else {
                parts.append("(明细未解析)")
            }
            lines.append(parts.joined(separator: " "))
        }

        if tallied {
            let net = netAcquire - netDispose
            let tilt = net > 0 ? "净买入" : (net < 0 ? "净卖出" : "持平")
            lines.append("近期合计：买入 \(humanShares(netAcquire)) 股 / 卖出 "
                + "\(humanShares(netDispose)) 股 → \(tilt) \(humanShares(abs(net))) 股")
        }

        return ToolResultBounding.bound(lines.joined(separator: "\n"))
    }
}

// MARK: - 2) 财务 us.financials

public struct USFinancialsTool: AgentTool {
    public let provider: SECEdgarProvider
    public init(provider: SECEdgarProvider) { self.provider = provider }

    public var spec: ToolSpec {
        ToolSpec(
            name: "us.financials",
            description: "US company financials (财务) from SEC EDGAR's free XBRL "
                + "company-concept API. Returns the latest 营收 / 净利润 / 每股收益 / "
                + "总资产 / 股东权益 with the report period and YoY where computable. "
                + "US-listed issuers only (bare symbols like AAPL / MSFT); not "
                + "CN / HK / international tickers.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "symbol": { "type": "string", "description": "US-listed ticker, e.g. AAPL / MSFT / NVDA" }
              },
              "required": ["symbol"]
            }
            """)
    }

    private struct Args: Decodable { let symbol: String }

    public func call(arguments: Data) async throws -> String {
        let args = try JSONDecoder().decode(Args.self, from: arguments)
        let raw = args.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUSSymbol(raw) else { return usGateFailureMessage(raw) }
        let sym = raw.uppercased()

        guard await provider.cik(for: sym) != nil else {
            return "未找到 \(sym) 的 SEC 备案（可能非美股或代码有误）。"
        }
        let metrics = await provider.financials(symbol: sym)
        guard !metrics.isEmpty else {
            return "\(sym)：SEC XBRL 未返回可用财务指标。"
        }

        var lines = ["\(sym) 财务指标 (SEC XBRL)"]
        for m in metrics {
            let isPerShare = m.unit == "USD/shares"
            func fmt(_ v: Double) -> String { isPerShare ? String(format: "$%.2f", v) : humanUSD(v) }

            // Prefer the annual point for the headline; fall back to latest.
            let head = m.annual ?? m.latest
            guard let h = head else { continue }
            var s = "\(m.label): \(fmt(h.value))（\(h.end) \(h.form)）"
            if let yoy = m.annualYoY {
                s += String(format: "，同比 %+.1f%%", yoy)
            }
            // If the latest non-annual point is newer than the annual, append it.
            if let latest = m.latest, let annual = m.annual,
               latest.end > annual.end, latest.form != annual.form {
                s += "；最新 \(fmt(latest.value))（\(latest.end) \(latest.form)）"
            }
            lines.append(s)
        }

        return ToolResultBounding.bound(lines.joined(separator: "\n"))
    }
}

// MARK: - Convenience grouping

public enum USEdgarTools {
    /// The two SEC EDGAR tools, backed by one shared fetcher.
    public static func all(
        provider: SECEdgarProvider = SECEdgarProvider()
    ) -> [any AgentTool] {
        [InsiderTool(provider: provider), USFinancialsTool(provider: provider)]
    }

    public static let names = ["us.insider", "us.financials"]
}
