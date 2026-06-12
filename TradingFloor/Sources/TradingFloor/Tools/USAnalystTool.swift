import Foundation

/// Always-on AgentTool surfacing free Yahoo Finance analyst data via the
/// `quoteSummary` cookie+crumb flow:
///
///   • 分析师评级分布 (strongBuy / buy / hold / sell / strongSell)
///   • 目标价 targetMean + 当前价
///   • 推荐 recommendationKey
///   • 下次财报日 (next earnings)
///
/// US + international (no CN gate — Yahoo covers global symbols; a CN/HK canonical
/// like `0700.HK` works on Yahoo too). Yahoo rate-limits and periodically changes
/// the crumb flow; when the handshake fails the provider returns nil and this
/// tool reports 暂不可用.
public struct USAnalystTool: AgentTool {
    public let provider: YahooQuoteSummaryProvider
    public init(provider: YahooQuoteSummaryProvider) { self.provider = provider }

    public var spec: ToolSpec {
        ToolSpec(
            name: "us.analyst",
            description: "Analyst ratings (分析师评级) for a stock from Yahoo Finance "
                + "quoteSummary (free). Returns the strongBuy/buy/hold/sell rating "
                + "distribution, mean target price (目标价) vs current price, the "
                + "consensus recommendation, and the next earnings date (下次财报日). "
                + "Works for US and international symbols (e.g. AAPL / MSFT / 0700.HK); "
                + "may be temporarily unavailable if Yahoo throttles.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "symbol": { "type": "string", "description": "Ticker, e.g. AAPL / MSFT / 0700.HK" }
              },
              "required": ["symbol"]
            }
            """)
    }

    private struct Args: Decodable { let symbol: String }

    public func call(arguments: Data) async throws -> String {
        let args = try JSONDecoder().decode(Args.self, from: arguments)
        let raw = args.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "未提供股票代码。" }
        let sym = raw.uppercased()

        guard let s = await provider.summary(symbol: sym) else {
            return "\(sym)：分析师数据暂不可用（Yahoo quoteSummary 接口被限流或已变更）。"
        }

        var lines = ["\(sym) 分析师评级 (Yahoo)"]

        if let total = s.totalAnalysts {
            func n(_ v: Int?) -> String { String(v ?? 0) }
            lines.append("评级分布（共 \(total) 家）：强烈买入 \(n(s.strongBuy))｜买入 "
                + "\(n(s.buy))｜持有 \(n(s.hold))｜卖出 \(n(s.sell))｜强烈卖出 \(n(s.strongSell))")
        } else {
            lines.append("评级分布：暂无")
        }

        if let key = s.recommendationKey {
            lines.append("综合推荐：\(key)")
        }

        if let tgt = s.targetMean {
            var t = "平均目标价：$\(String(format: "%.2f", tgt))"
            if let cur = s.currentPrice {
                t += "（当前 $\(String(format: "%.2f", cur))"
                if cur > 0 {
                    let up = (tgt - cur) / cur * 100
                    t += String(format: "，上行空间 %+.1f%%", up)
                }
                t += "）"
            }
            lines.append(t)
        }

        if let pe = s.forwardPE {
            lines.append("预期市盈率(forward P/E)：\(String(format: "%.1f", pe))")
        }

        if let d = s.nextEarningsDate {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            lines.append("下次财报日：\(df.string(from: d))")
        }

        if lines.count == 1 {
            return "\(sym)：Yahoo 未返回可用的分析师/财报数据。"
        }
        return ToolResultBounding.bound(lines.joined(separator: "\n"))
    }
}

// MARK: - Convenience grouping

public enum USAnalystTools {
    /// The single Yahoo analyst tool, backed by one shared provider.
    public static func all(
        provider: YahooQuoteSummaryProvider = YahooQuoteSummaryProvider()
    ) -> [any AgentTool] {
        [USAnalystTool(provider: provider)]
    }

    public static let names = ["us.analyst"]
}
