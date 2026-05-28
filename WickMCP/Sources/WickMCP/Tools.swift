import Foundation
import TradingFloor

/// Bundles all exposed MCP tools behind a single async dispatcher the
/// server can drive. The dispatch table is structured as a switch on
/// tool name so adding a new tool is one case-addition plus an `inputSchema`
/// entry in `specs`.
final class ToolHost {
    let market: any MarketDataProvider
    /// Concrete EastMoney handle for raw-bar access. The router knows how
    /// to dispatch snapshots but `dailyBars(symbol:)` is EastMoney-specific
    /// today; if and when an FMP/Yahoo equivalent lands, this widens to a
    /// protocol.
    let eastMoney: EastMoneyMarketDataProvider

    init(market: any MarketDataProvider,
         eastMoney: EastMoneyMarketDataProvider) {
        self.market = market
        self.eastMoney = eastMoney
    }

    /// JSON-Schema-style descriptors returned by `tools/list`. Stored as
    /// `[String: Any]` (not Codable) because each tool's `inputSchema` is
    /// a free-form JSON Schema and roundtripping it through Codable types
    /// is more work than this should warrant.
    var specs: [[String: Any]] {
        [
            snapshotSpec,
            candlesSpec,
            holdingsSpec,
            watchlistSpec,
            portfolioSpec
        ]
    }

    /// Dispatch one tool invocation. Returns the `content` array MCP
    /// expects (one or more typed content blocks). `MCPToolError.unknown`
    /// is reserved for "tool name doesn't exist" so the server can map it
    /// to the right protocol error.
    func call(name: String, arguments: [String: Any]) async throws -> [[String: Any]] {
        switch name {
        case "wick.snapshot":   return try await snapshot(arguments: arguments)
        case "wick.candles":    return try await candles(arguments: arguments)
        case "wick.holdings":   return try holdings(arguments: arguments)
        case "wick.watchlist":  return try watchlist(arguments: arguments)
        case "wick.portfolio":  return try await portfolio(arguments: arguments)
        default:                throw MCPToolError.unknown(name)
        }
    }

    // MARK: - wick.snapshot

    private var snapshotSpec: [String: Any] {
        [
            "name": "wick.snapshot",
            "description": """
            Fetch a point-in-time market snapshot for one ticker. Returns \
            price summary, technicals (RSI / MACD / SMA), fundamentals \
            (PE, PB, ROE, 营收 YoY, 净利 YoY, 报告期, etc.), and recent news \
            when available. Routes Chinese A-share / Hong Kong tickers \
            (`.SS` / `.SZ` / `.HK`) to EastMoney; everything else falls \
            back to the configured US provider.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ticker": [
                        "type": "string",
                        "description": "Canonical symbol — e.g. 'NVDA', '600519.SS', '0700.HK'."
                    ]
                ],
                "required": ["ticker"]
            ]
        ]
    }

    private func snapshot(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let ticker = arguments["ticker"] as? String, !ticker.isEmpty else {
            throw MCPToolError.invalidArgument("`ticker` must be a non-empty string")
        }
        let snap = try await market.snapshot(symbol: ticker, asOf: Date())
        let markdown = render(snap)
        let json = try jsonEncode(snap)
        return [
            ["type": "text", "text": markdown],
            ["type": "text", "text": "```json\n\(json)\n```"]
        ]
    }

    // MARK: - wick.candles

    private var candlesSpec: [String: Any] {
        [
            "name": "wick.candles",
            "description": """
            Fetch daily OHLCV bars for a Chinese A-share / Hong Kong ticker \
            (US bars not yet supported on this surface). Returns up to \
            `limit` bars (default 60, max 300), ordered chronologically. \
            Includes change-percent + amount so the LLM can reason about \
            volume divergence and momentum directly.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ticker": [
                        "type": "string",
                        "description": "CN/HK symbol — `600519.SS`, `0700.HK`, etc."
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Number of recent sessions (default 60, max 300).",
                        "default": 60,
                        "minimum": 1,
                        "maximum": 300
                    ]
                ],
                "required": ["ticker"]
            ]
        ]
    }

    private func candles(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let ticker = arguments["ticker"] as? String, !ticker.isEmpty else {
            throw MCPToolError.invalidArgument("`ticker` must be a non-empty string")
        }
        let limit = min((arguments["limit"] as? Int) ?? 60, 300)
        let bars = try await eastMoney.dailyBars(symbol: ticker, limit: limit)
        guard !bars.isEmpty else {
            return [["type": "text",
                     "text": "No candle data for \(ticker) — non-CN tickers aren't supported on this tool yet."]]
        }
        var lines: [String] = ["# \(ticker) — \(bars.count) daily bars",
                               "",
                               "| Date | Open | Close | High | Low | %Δ | Amount |",
                               "|---|---:|---:|---:|---:|---:|---:|"]
        for b in bars {
            lines.append("| \(b.date) | \(fmt(b.open)) | \(fmt(b.close)) | \(fmt(b.high)) | \(fmt(b.low)) | \(String(format: "%+.2f%%", b.changePercent)) | \(bigCNY(b.amount)) |")
        }
        let markdown = lines.joined(separator: "\n")
        let json = try encodeJSON(bars)
        return [
            ["type": "text", "text": markdown],
            ["type": "text", "text": "```json\n\(json)\n```"]
        ]
    }

    // MARK: - wick.holdings

    private var holdingsSpec: [String: Any] {
        [
            "name": "wick.holdings",
            "description": """
            List the user's holdings — every individual transaction (buy / \
            sell, ticker, qty, price, currency, date). Sourced from the \
            shared App Group container the main Wick app writes to. Read-only.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "symbol": [
                        "type": "string",
                        "description": "Optional filter — only return transactions for this ticker."
                    ]
                ]
            ]
        ]
    }

    private func holdings(arguments: [String: Any]) throws -> [[String: Any]] {
        let filter = (arguments["symbol"] as? String).flatMap { $0.isEmpty ? nil : $0.uppercased() }
        var rows = SharedStore.holdings()
        if let s = filter {
            rows = rows.filter { $0.symbol.uppercased() == s }
        }
        rows.sort { $0.date < $1.date }
        return holdingsContent(rows: rows, filter: filter)
    }

    private func holdingsContent(rows: [SharedHolding],
                                 filter: String?) -> [[String: Any]]
    {
        if rows.isEmpty {
            let msg = filter == nil
                ? "No holdings recorded. Open Wick → Portfolio to add transactions."
                : "No holdings for \(filter!)."
            return [["type": "text", "text": msg]]
        }
        var lines: [String] = [
            "# Holdings\(filter.map { " (filter: \($0))" } ?? "")",
            "",
            "| Date | Symbol | Side | Qty | Price | Currency |",
            "|---|---|---|---:|---:|---|"
        ]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        for r in rows {
            lines.append("| \(df.string(from: r.date)) | \(r.symbol) | \(r.side) | \(fmt(r.quantity)) | \(fmt(r.price)) | \(r.currency) |")
        }
        // Add a positions summary if no filter — that's the more useful
        // shape when the LLM asks "what does the user hold?"
        if filter == nil {
            lines.append("")
            lines.append("**Net positions**")
            for pos in positions(rows: rows) {
                lines.append("- \(pos.symbol) (\(pos.name)): net \(fmt(pos.net)), avg buy \(fmt(pos.avgBuyPrice)) \(pos.currency)")
            }
        }
        let markdown = lines.joined(separator: "\n")
        let json = (try? encodeJSON(rows)) ?? "[]"
        return [
            ["type": "text", "text": markdown],
            ["type": "text", "text": "```json\n\(json)\n```"]
        ]
    }

    private struct PositionView {
        let symbol: String
        let name: String
        let net: Double
        let avgBuyPrice: Double
        let currency: String
    }

    private func positions(rows: [SharedHolding]) -> [PositionView] {
        let grouped = Dictionary(grouping: rows, by: \.symbol)
        return grouped.compactMap { (symbol, txs) -> PositionView? in
            guard let any = txs.first else { return nil }
            let buys  = txs.filter { $0.side == "buy" }
            let sells = txs.filter { $0.side == "sell" }
            let buyQty = buys.reduce(0) { $0 + $1.quantity }
            let net = buyQty - sells.reduce(0) { $0 + $1.quantity }
            let avg: Double = {
                guard buyQty > 0 else { return 0 }
                let w = buys.reduce(0) { $0 + $1.quantity * $1.price }
                return w / buyQty
            }()
            return PositionView(symbol: symbol, name: any.name, net: net,
                                avgBuyPrice: avg, currency: any.currency)
        }.sorted { $0.symbol < $1.symbol }
    }

    // MARK: - wick.watchlist

    private var watchlistSpec: [String: Any] {
        [
            "name": "wick.watchlist",
            "description": """
            List the user's watchlist groups and their symbols. Read-only.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [:]
            ]
        ]
    }

    private func watchlist(arguments: [String: Any]) throws -> [[String: Any]] {
        let groups = SharedStore.watchlistGroups()
        if groups.isEmpty {
            return [["type": "text",
                     "text": "No watchlist groups. Add some in Wick's sidebar."]]
        }
        var lines: [String] = ["# Watchlist groups", ""]
        for g in groups {
            lines.append("**\(g.name)** (\(g.symbols.count) symbols)")
            if g.symbols.isEmpty {
                lines.append("- _empty_")
            } else {
                for s in g.symbols { lines.append("- \(s)") }
            }
            lines.append("")
        }
        let json = (try? encodeJSON(groups)) ?? "[]"
        return [
            ["type": "text", "text": lines.joined(separator: "\n")],
            ["type": "text", "text": "```json\n\(json)\n```"]
        ]
    }

    // MARK: - wick.portfolio (rolled-up positions + live PnL)

    private var portfolioSpec: [String: Any] {
        [
            "name": "wick.portfolio",
            "description": """
            Roll up the user's holdings into one position per symbol and \
            attach the latest market price + P/L per position. Uses \
            `wick.snapshot` under the hood for each unique symbol — slower \
            than `wick.holdings` (one network call per ticker) but \
            gives the LLM a portfolio-level view it can reason over.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [:]
            ]
        ]
    }

    private func portfolio(arguments: [String: Any]) async throws -> [[String: Any]] {
        let rows = SharedStore.holdings()
        guard !rows.isEmpty else {
            return [["type": "text",
                     "text": "No holdings recorded — nothing to roll up."]]
        }
        let positions = positions(rows: rows)
        // Fetch snapshots in parallel to keep latency reasonable even on
        // 20-symbol portfolios. Best-effort: a per-symbol failure drops
        // that row's price rather than failing the whole tool. Capture
        // the provider locally so the task closure doesn't pull `self`
        // through the Sendable boundary.
        let dataProvider = market
        let prices: [String: Double] = await withTaskGroup(of: (String, Double?).self) { group in
            for p in positions {
                let sym = p.symbol
                group.addTask {
                    let s = try? await dataProvider.snapshot(symbol: sym, asOf: Date())
                    return (sym, s?.lastPrice)
                }
            }
            var dict: [String: Double] = [:]
            for await (sym, price) in group {
                if let price { dict[sym] = price }
            }
            return dict
        }
        var lines: [String] = [
            "# Portfolio",
            "",
            "| Symbol | Net qty | Avg buy | Last | Cost | Market | P/L | P/L % |",
            "|---|---:|---:|---:|---:|---:|---:|---:|"
        ]
        var rolled: [[String: Any]] = []
        var totalCost = 0.0, totalMarket = 0.0
        for p in positions where p.net != 0 {
            let last = prices[p.symbol]
            let cost = p.net * p.avgBuyPrice
            let market = last.map { $0 * p.net } ?? 0
            let pnl = last.map { ($0 - p.avgBuyPrice) * p.net }
            let pnlPct = last.flatMap { l -> Double? in
                p.avgBuyPrice == 0 ? nil : (l - p.avgBuyPrice) / p.avgBuyPrice * 100
            }
            lines.append("| \(p.symbol) | \(fmt(p.net)) | \(fmt(p.avgBuyPrice)) | \(last.map(fmt) ?? "—") | \(fmt(cost)) | \(last.map { _ in fmt(market) } ?? "—") | \(pnl.map { String(format: "%+.2f", $0) } ?? "—") | \(pnlPct.map { String(format: "%+.2f%%", $0) } ?? "—") |")
            if last != nil { totalCost += cost; totalMarket += market }
            rolled.append([
                "symbol": p.symbol,
                "name": p.name,
                "netQuantity": p.net,
                "averageBuyPrice": p.avgBuyPrice,
                "currency": p.currency,
                "lastPrice": last as Any,
                "costBasis": cost,
                "marketValue": last != nil ? market : NSNull(),
                "unrealizedPnL": pnl as Any
            ])
        }
        if totalCost != 0 {
            let totalPnL = totalMarket - totalCost
            let totalPct = totalPnL / totalCost * 100
            lines.append("")
            lines.append("**Total cost basis:** \(fmt(totalCost))")
            lines.append("**Total market value:** \(fmt(totalMarket))")
            lines.append("**Unrealized P/L:** \(String(format: "%+.2f (%+.2f%%)", totalPnL, totalPct))")
        }
        let payload: [String: Any] = ["positions": rolled,
                                       "totalCostBasis": totalCost,
                                       "totalMarketValue": totalMarket]
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys])
        return [
            ["type": "text", "text": lines.joined(separator: "\n")],
            ["type": "text", "text": "```json\n\(String(data: data, encoding: .utf8) ?? "{}")\n```"]
        ]
    }

    // MARK: - Snapshot rendering helpers

    private func render(_ s: MarketSnapshot) -> String {
        var lines: [String] = []
        lines.append("# \(s.symbol)")
        if let p = s.lastPrice {
            lines.append("**Last price:** \(String(format: "%.2f", p))")
        }
        if !s.priceSummary.isEmpty {
            lines.append("**Price action:** \(s.priceSummary)")
        }
        if !s.technicals.isEmpty {
            lines.append("**Technicals:** \(s.technicals)")
        }
        if !s.fundamentals.isEmpty {
            lines.append("")
            lines.append("**Fundamentals**")
            for (k, v) in s.fundamentals.sorted(by: { $0.key < $1.key }) {
                lines.append("- \(k): \(v)")
            }
        }
        if !s.news.isEmpty {
            lines.append("")
            lines.append("**Recent headlines**")
            for h in s.news.prefix(10) { lines.append("- \(h)") }
        }
        if !s.macro.isEmpty {
            lines.append("")
            lines.append("**Macro backdrop**")
            lines.append(s.macro)
        }
        return lines.joined(separator: "\n")
    }

    private func jsonEncode(_ s: MarketSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(s)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private func bigCNY(_ value: Double) -> String {
        switch abs(value) {
        case 1e8...:  return String(format: "%.2f亿", value / 1e8)
        case 1e4...:  return String(format: "%.1f万", value / 1e4)
        default:      return String(format: "%.0f", value)
        }
    }
}
