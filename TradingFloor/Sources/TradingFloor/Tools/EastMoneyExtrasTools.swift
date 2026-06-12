import Foundation

/// Four always-on AgentTools that surface the free EastMoney (东方财富) extras
/// to the chat agent (Wicker) — a free replacement for tushare's points-gated
/// data, for A-share / HK analysis:
///
///   • `cn.fund_flow`    资金流向 — main-force net inflow + multi-day trend
///   • `cn.financials`   F10 财务指标 — latest report's 营收/净利/同比/EPS/ROE/毛利率
///   • `cn.dragon_tiger` 龙虎榜 — a stock's recent appearances OR the latest list
///   • `cn.limit_up`     涨停板 — whole-market limit-up pool for a date
///
/// Each validates the symbol is CN where applicable (via `CNSymbol.parse`),
/// fetches through a shared `EastMoneyExtrasProvider`, and returns a compact
/// Chinese-labelled summary string (亿/万 formatting). Big results are clamped
/// with `ToolResultBounding`. All no-key; the agent calls them when a CN ticker
/// is in play.

// MARK: - Shared helpers

private func nonCNMessage(_ symbol: String) -> String {
    "「\(symbol)」不是 A 股 / 港股代码——该工具仅支持中国市场（如 600519.SS、000001.SZ、0700.HK）。"
}

// MARK: - 1) 资金流 cn.fund_flow

public struct FundFlowTool: AgentTool {
    public let provider: EastMoneyExtrasProvider
    public init(provider: EastMoneyExtrasProvider) { self.provider = provider }

    public var spec: ToolSpec {
        ToolSpec(
            name: "cn.fund_flow",
            description: "A股资金流向 (main-force capital flow) for a Chinese A-share. "
                + "Returns the latest day's 主力净流入 (亿) and net % of turnover, the "
                + "超大单/大单 split, and the multi-day cumulative trend. A-shares only "
                + "(HK has no order-size disclosure).",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "symbol": { "type": "string", "description": "A-share ticker, e.g. 600519.SS / 000001.SZ" },
                "days":   { "type": "integer", "description": "Trailing sessions to summarise (default 5)" }
              },
              "required": ["symbol"]
            }
            """)
    }

    private struct Args: Decodable { let symbol: String; let days: Int? }

    public func call(arguments: Data) async throws -> String {
        let args = try JSONDecoder().decode(Args.self, from: arguments)
        guard let canonical = CNSymbol.parse(args.symbol),
              let market = CNSymbol.market(canonical),
              market == .shanghai || market == .shenzhen
        else { return nonCNMessage(args.symbol) }

        let days = max(args.days ?? 5, 1)
        let rows = await provider.fundFlow(symbol: canonical, days: days)
        guard let latest = rows.last else {
            return "未获取到 \(canonical) 的资金流数据（可能是新股 / 停牌，或源暂不可用）。"
        }

        let dir = latest.main >= 0 ? "净流入" : "净流出"
        var lines = [
            "\(canonical) 资金流向 — 最新交易日 \(latest.date)",
            "主力\(dir) \(Formatting.bigCNY(latest.main))（占成交额 \(Formatting.percent(latest.mainPct))）",
            "超大单 \(Formatting.bigCNY(latest.superBig))；大单 \(Formatting.bigCNY(latest.big))；"
                + "中单 \(Formatting.bigCNY(latest.medium))；小单 \(Formatting.bigCNY(latest.small))",
        ]
        if rows.count > 1 {
            let cumulative = rows.reduce(0) { $0 + $1.main }
            let inflowDays = rows.filter { $0.main > 0 }.count
            lines.append("近\(rows.count)日主力累计 \(Formatting.bigCNY(cumulative))"
                + "（\(rows.count)日中 \(inflowDays) 日净流入）")
            let trend = rows.map { "\($0.date.suffix(5)): \(Formatting.bigCNY($0.main))" }
                .joined(separator: " | ")
            lines.append("逐日主力: \(trend)")
        }
        return ToolResultBounding.bound(lines.joined(separator: "\n"))
    }
}

// MARK: - 2) F10 财务指标 cn.financials

public struct FinancialsTool: AgentTool {
    public let provider: EastMoneyExtrasProvider
    public init(provider: EastMoneyExtrasProvider) { self.provider = provider }

    public var spec: ToolSpec {
        ToolSpec(
            name: "cn.financials",
            description: "F10 财务指标 (key financial indicators) for a Chinese A-share or "
                + "HK stock. Returns the latest report's 营业收入 (亿), 归母净利润 (亿), "
                + "同比增速, 每股收益 (EPS), 净资产收益率 (ROE), 毛利率/净利率, 资产负债率, "
                + "plus a few prior periods for trend.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "symbol":  { "type": "string", "description": "CN ticker, e.g. 600519.SS / 000001.SZ / 0700.HK" },
                "periods": { "type": "integer", "description": "Reporting periods to return, newest first (default 4)" }
              },
              "required": ["symbol"]
            }
            """)
    }

    private struct Args: Decodable { let symbol: String; let periods: Int? }

    public func call(arguments: Data) async throws -> String {
        let args = try JSONDecoder().decode(Args.self, from: arguments)
        guard let canonical = CNSymbol.parse(args.symbol) else {
            return nonCNMessage(args.symbol)
        }
        let periods = max(args.periods ?? 4, 1)
        let reports = await provider.financials(symbol: canonical, periods: periods)
        guard let latest = reports.first else {
            return "未获取到 \(canonical) 的财务指标数据（源暂不可用或该标的无 F10 数据）。"
        }

        func pct(_ v: Double?) -> String { v.map { Formatting.percent($0) } ?? "—" }
        func money(_ v: Double?) -> String { v.map { Formatting.bigCNY($0) } ?? "—" }
        func num(_ v: Double?, _ fmt: String = "%.2f") -> String {
            v.map { String(format: fmt, $0) } ?? "—"
        }

        var lines = [
            "\(canonical) 财务指标 — \(latest.reportName ?? latest.reportDate ?? "最新报告期")",
            "营业收入 \(money(latest.revenue))（同比 \(pct(latest.revenueYoY))）",
            "归母净利润 \(money(latest.netProfit))（同比 \(pct(latest.netProfitYoY))）",
            "EPS \(num(latest.eps)) 元；ROE(加权) \(num(latest.roe, "%.2f"))%",
        ]
        var ratios: [String] = []
        if let gm = latest.grossMargin { ratios.append("毛利率 \(String(format: "%.2f", gm))%") }
        if let nm = latest.netMargin { ratios.append("净利率 \(String(format: "%.2f", nm))%") }
        if let dr = latest.debtRatio { ratios.append("资产负债率 \(String(format: "%.2f", dr))%") }
        if let bps = latest.bps { ratios.append("每股净资产 \(String(format: "%.2f", bps)) 元") }
        if !ratios.isEmpty { lines.append(ratios.joined(separator: "；")) }

        if reports.count > 1 {
            lines.append("历史报告期（营收 / 净利 / 净利同比）:")
            for r in reports.prefix(periods) {
                let tag = r.reportName ?? r.reportDate ?? "—"
                lines.append("  \(tag): \(money(r.revenue)) / \(money(r.netProfit)) / \(pct(r.netProfitYoY))")
            }
        }
        return ToolResultBounding.bound(lines.joined(separator: "\n"))
    }
}

// MARK: - 3) 龙虎榜 cn.dragon_tiger

public struct DragonTigerTool: AgentTool {
    public let provider: EastMoneyExtrasProvider
    public init(provider: EastMoneyExtrasProvider) { self.provider = provider }

    public var spec: ToolSpec {
        ToolSpec(
            name: "cn.dragon_tiger",
            description: "龙虎榜 (dragon-tiger list) — the exchange's daily disclosure of "
                + "the top buy/sell seats. Pass a `symbol` to get that A-share's recent "
                + "appearances (上榜原因, 净买入额, 席位解读 机构/游资); omit `symbol` to get "
                + "the latest market-wide list (largest 净买入 first).",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "symbol": { "type": "string", "description": "Optional A-share ticker, e.g. 600519.SS. Omit for the market-wide latest list." },
                "limit":  { "type": "integer", "description": "Max rows to return (default 10 per-stock, 15 market-wide)" }
              }
            }
            """)
    }

    private struct Args: Decodable { let symbol: String?; let limit: Int? }

    public func call(arguments: Data) async throws -> String {
        let args = try JSONDecoder().decode(Args.self, from: arguments)

        // Per-stock path: validate CN.
        var canonical: String? = nil
        if let s = args.symbol, !s.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let c = CNSymbol.parse(s),
                  let m = CNSymbol.market(c), m == .shanghai || m == .shenzhen
            else { return nonCNMessage(s) }
            canonical = c
        }

        let limit = max(args.limit ?? (canonical == nil ? 15 : 10), 1)
        let rows = await provider.dragonTiger(symbol: canonical, pageSize: max(limit, 30))
        guard !rows.isEmpty else {
            return canonical.map { "\($0) 近期未上龙虎榜（或源暂不可用）。" }
                ?? "未获取到最新龙虎榜数据（可能非交易日或源暂不可用）。"
        }

        func money(_ v: Double?) -> String { v.map { Formatting.bigCNY($0) } ?? "—" }

        if let canonical {
            var lines = ["\(canonical) 龙虎榜 — 近 \(min(rows.count, limit)) 次上榜:"]
            for r in rows.prefix(limit) {
                var parts = ["\(r.date)"]
                if let cr = r.changeRate { parts.append("涨跌 \(String(format: "%+.2f", cr))%") }
                parts.append("净买入 \(money(r.netAmount))")
                if let why = r.explanation, !why.isEmpty { parts.append(why) }
                if let seat = r.explain, !seat.isEmpty { parts.append(seat) }
                lines.append("  • " + parts.joined(separator: "；"))
            }
            return ToolResultBounding.bound(lines.joined(separator: "\n"))
        } else {
            // Market-wide: sort by 净买入 desc for the most actionable view.
            let sorted = rows.sorted { ($0.netAmount ?? 0) > ($1.netAmount ?? 0) }
            let date = rows.first?.date ?? ""
            var lines = ["龙虎榜 最新一日 \(date) — 共 \(rows.count) 条，按净买入排序 (Top \(min(limit, sorted.count))):"]
            for r in sorted.prefix(limit) {
                let nm = "\(r.name ?? "")(\(r.code ?? ""))"
                var parts = [nm, "净买入 \(money(r.netAmount))"]
                if let cr = r.changeRate { parts.append("\(String(format: "%+.2f", cr))%") }
                if let why = r.explanation, !why.isEmpty { parts.append(why) }
                lines.append("  • " + parts.joined(separator: "；"))
            }
            return ToolResultBounding.bound(lines.joined(separator: "\n"))
        }
    }
}

// MARK: - 4) 涨停板 cn.limit_up

public struct LimitUpTool: AgentTool {
    public let provider: EastMoneyExtrasProvider
    public init(provider: EastMoneyExtrasProvider) { self.provider = provider }

    public var spec: ToolSpec {
        ToolSpec(
            name: "cn.limit_up",
            description: "涨停板 (whole-market limit-up pool) for an A-share trading day. "
                + "Returns the total count of limit-up stocks plus the top names ranked by "
                + "连板数 (consecutive limit-ups) then 封单额 (seal amount), with each name's "
                + "行业 and first-seal time. Defaults to the most recent trading day.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "date":  { "type": "string", "description": "Trading day as yyyyMMdd (e.g. 20260612). Defaults to the latest trading day." },
                "limit": { "type": "integer", "description": "Top N names to list (default 15)" }
              }
            }
            """)
    }

    private struct Args: Decodable { let date: String?; let limit: Int? }

    public func call(arguments: Data) async throws -> String {
        let args = try JSONDecoder().decode(Args.self, from: arguments)
        let limit = max(args.limit ?? 15, 1)

        guard let pool = await provider.limitUpPool(date: Self.normalize(args.date)) else {
            let note = args.date.map { "（\($0)）" } ?? ""
            return "未获取到涨停板数据\(note)——可能是非交易日、盘前尚无涨停，或源暂不可用。"
        }

        // Rank by 连板 then 封单额 — what a CN trader scans first.
        let ranked = pool.stocks.sorted {
            $0.consecutive != $1.consecutive
                ? $0.consecutive > $1.consecutive
                : $0.sealAmount > $1.sealAmount
        }
        let maxLb = pool.stocks.map(\.consecutive).max() ?? 1
        let multiBoard = pool.stocks.filter { $0.consecutive >= 2 }.count

        var lines = [
            "涨停板 \(pool.date) — 涨停 \(pool.total) 家；连板 ≥2 的 \(multiBoard) 家；最高 \(maxLb) 连板",
            "Top \(min(limit, ranked.count))（按连板/封单排序）:",
        ]
        for s in ranked.prefix(limit) {
            var parts = ["\(s.name)(\(s.code))"]
            parts.append(s.consecutive >= 2 ? "\(s.consecutive)连板" : "首板")
            parts.append("封单 \(Formatting.bigCNY(s.sealAmount))")
            if let ind = s.industry { parts.append(ind) }
            if let t = s.firstSealTime { parts.append("首封 \(t)") }
            lines.append("  • " + parts.joined(separator: "；"))
        }
        return ToolResultBounding.bound(lines.joined(separator: "\n"))
    }

    /// Accept `yyyyMMdd`, `yyyy-MM-dd`, or `yyyy/MM/dd`; strip separators.
    private static func normalize(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let digits = raw.filter(\.isNumber)
        return digits.count == 8 ? digits : nil
    }
}

// MARK: - Convenience grouping

public enum EastMoneyExtrasTools {
    /// All four CN extras tools backed by one shared fetcher instance.
    public static func all(
        provider: EastMoneyExtrasProvider = EastMoneyExtrasProvider()
    ) -> [any AgentTool] {
        [
            FundFlowTool(provider: provider),
            FinancialsTool(provider: provider),
            DragonTigerTool(provider: provider),
            LimitUpTool(provider: provider),
        ]
    }

    public static let names = ["cn.fund_flow", "cn.financials", "cn.dragon_tiger", "cn.limit_up"]
}
