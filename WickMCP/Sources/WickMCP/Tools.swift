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
    /// Loaded Wicker skill playbooks. The `wick.methodology` tool reads
    /// from this and hands the agent our analysis recipe so it can drive
    /// its own multi-step reasoning instead of asking us to do it for it.
    let skills: SkillRegistry

    init(market: any MarketDataProvider,
         eastMoney: EastMoneyMarketDataProvider,
         skills: SkillRegistry = SkillRegistry()) {
        self.market = market
        self.eastMoney = eastMoney
        self.skills = skills
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
            portfolioSpec,
            methodologySpec,
            writeReportSpec,
            webNavigateSpec,
            webReadSpec,
            webSnapshotSpec,
            xueqiuDiscussionSpec,
            xDiscussionSpec
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
        case "wick.methodology": return try await methodology(arguments: arguments)
        case "wick.write_report": return try writeReport(arguments: arguments)
        case "wick.web_navigate":      return try await webNavigate(arguments: arguments)
        case "wick.web_read":          return try await webRead(arguments: arguments)
        case "wick.web_snapshot":      return try await webSnapshot(arguments: arguments)
        case "wick.xueqiu_discussion": return try await xueqiuDiscussion(arguments: arguments)
        case "wick.x_discussion":      return try await xDiscussion(arguments: arguments)
        default:                throw MCPToolError.unknown(name)
        }
    }

    // MARK: - Live cross-process bridge tools (TODO #39)
    //
    // These five tools reach capabilities that live in the GUI app process —
    // the `@MainActor` WebKit-backed `BrowserSessionManager` (navigate / read /
    // snapshot) and the 雪球 / X discussion scrapers (logged-in cookie jars). The
    // helper is a SEPARATE sandboxed subprocess, so it can't call those directly.
    // Instead each tool enqueues a `BridgeRequest` into the App-Group `Bridge/`
    // dir (the only sanctioned IPC channel) and polls for the GUI's
    // `BridgeResponse`. If the GUI isn't running — or the user hasn't opted into
    // exposing the browser over MCP — no response ever lands and we return a
    // clear, non-hanging message telling the user how to enable it.
    //
    // Surface is READ-only by design: navigate + read + snapshot + 雪球/X reads.
    // Page-mutating ops (click / type / eval) are deliberately NOT exposed over
    // MCP in this pass — driving the user's logged-in session from a third-party
    // agent is already sensitive; mutation stays in-app behind the live panel.

    /// How long we wait for the GUI to answer before giving up. The GUI polls
    /// the bridge ~every 0.4s; 20s leaves ample room for a slow page load while
    /// never hanging the MCP client indefinitely.
    private static let bridgeTimeout: TimeInterval = 20

    /// The standard "not enabled / not running" message — identical for every
    /// bridge tool so the calling agent learns the one switch to flip.
    private static let bridgeUnavailableText =
        "Wick 未运行，或未在「设置 → 工作流」开启『通过 MCP 暴露 Wicker 浏览器/社交』。请先启用后重试。"

    /// Enqueue a bridge request and poll for its response up to `bridgeTimeout`.
    /// Returns the GUI's rendered text on success, or the clear unavailable
    /// message on timeout / missing container. Never hangs, never throws.
    private func runBridge(tool: SharedBridge.Tool,
                           args: [String: JSONValue]) async -> [[String: Any]]
    {
        guard SharedBridge.isAvailable else {
            return [["type": "text", "text": Self.bridgeUnavailableText]]
        }
        let request = BridgeRequest(tool: tool.rawValue, args: args)
        guard SharedBridge.enqueueRequest(request) else {
            return [["type": "text", "text": Self.bridgeUnavailableText]]
        }
        let deadline = Date().addingTimeInterval(Self.bridgeTimeout)
        // Poll at ~0.2s — twice the GUI's cadence so we catch a fresh response
        // promptly without busy-spinning.
        while Date() < deadline {
            if let resp = SharedBridge.readResponse(id: request.id) {
                return [["type": "text", "text": resp.text]]
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Timed out — stop the GUI from later answering a dead request, and tell
        // the agent how to turn the feature on.
        SharedBridge.cancelRequest(id: request.id)
        return [["type": "text", "text": Self.bridgeUnavailableText]]
    }

    // MARK: wick.web_navigate

    private var webNavigateSpec: [String: Any] {
        [
            "name": "wick.web_navigate",
            "description": """
            Drive Wick's embedded browser to a URL and return the final URL + \
            page title once it settles. Operates the SAME logged-in browser tab \
            the user sees in Wick, so cookies/logins ride along. Read-only — it \
            navigates and reports; it does not click or type. Requires Wick to be \
            running with 『通过 MCP 暴露 Wicker 浏览器/社交』enabled (macOS 26+).
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string",
                            "description": "URL to load — scheme optional (defaults to https)."]
                ],
                "required": ["url"]
            ]
        ]
    }

    private func webNavigate(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let url = (arguments["url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty
        else { throw MCPToolError.invalidArgument("`url` must be a non-empty string") }
        return await runBridge(tool: .webNavigate, args: ["url": .string(url)])
    }

    // MARK: wick.web_read

    private var webReadSpec: [String: Any] {
        [
            "name": "wick.web_read",
            "description": """
            Read the visible text of Wick's current browser page (or the first \
            element matching a CSS `selector`). Returns the innerText, \
            whitespace-collapsed. Pair with `wick.web_navigate` first. Read-only. \
            Requires Wick running with the MCP browser exposure enabled.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "selector": ["type": "string",
                                 "description": "Optional CSS selector — omit to read the whole page body."]
                ]
            ]
        ]
    }

    private func webRead(arguments: [String: Any]) async throws -> [[String: Any]] {
        var args: [String: JSONValue] = [:]
        if let sel = (arguments["selector"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
            args["selector"] = .string(sel)
        }
        return await runBridge(tool: .webRead, args: args)
    }

    // MARK: wick.web_snapshot

    private var webSnapshotSpec: [String: Any] {
        [
            "name": "wick.web_snapshot",
            "description": """
            Take a token-efficient accessibility/DOM outline of Wick's current \
            browser page — a compact tree of interactive + textual nodes with \
            stable `ref:N` handles. The first call after a navigation returns the \
            full baseline; pass `full:true` to force a fresh one. `viewportOnly` \
            limits the walk to the visible region for big pages. Read-only. \
            Requires Wick running with the MCP browser exposure enabled.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "full": ["type": "boolean",
                             "description": "Force a fresh full baseline instead of a delta.",
                             "default": false],
                    "viewportOnly": ["type": "boolean",
                                     "description": "Walk only the visible region (+~1 screen).",
                                     "default": false]
                ]
            ]
        ]
    }

    private func webSnapshot(arguments: [String: Any]) async throws -> [[String: Any]] {
        var args: [String: JSONValue] = [:]
        if let full = arguments["full"] as? Bool { args["full"] = .bool(full) }
        if let vp = arguments["viewportOnly"] as? Bool { args["viewportOnly"] = .bool(vp) }
        return await runBridge(tool: .webSnapshot, args: args)
    }

    // MARK: wick.xueqiu_discussion

    private var xueqiuDiscussionSpec: [String: Any] {
        [
            "name": "wick.xueqiu_discussion",
            "description": """
            Read recent 雪球 (Xueqiu) discussion posts for a Chinese A-share / \
            Hong Kong ticker, using the user's logged-in 雪球 session inside Wick. \
            Returns author / text / 赞·评 counts / time per post. Read-only. CN/HK \
            symbols only (e.g. '600519.SS', '0700.HK'). Requires Wick running, \
            the user signed into 雪球, and the MCP browser exposure enabled.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "symbol": ["type": "string",
                               "description": "CN/HK symbol — '600519.SS', '0700.HK', etc."]
                ],
                "required": ["symbol"]
            ]
        ]
    }

    private func xueqiuDiscussion(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let symbol = (arguments["symbol"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !symbol.isEmpty
        else { throw MCPToolError.invalidArgument("`symbol` must be a non-empty string") }
        return await runBridge(tool: .xueqiuDiscussion, args: ["symbol": .string(symbol)])
    }

    // MARK: wick.x_discussion

    private var xDiscussionSpec: [String: Any] {
        [
            "name": "wick.x_discussion",
            "description": """
            Read recent X (Twitter) cashtag discussion ($SYMBOL) for a ticker, \
            using the user's logged-in X session inside Wick (US / intl markets). \
            Returns handle + tweet text per post. Read-only. The symbol is \
            reduced to its bare ticker before the `$` (e.g. 'AAPL'/'TSLA'). \
            Requires Wick running, the user signed into X, and the MCP browser \
            exposure enabled.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "symbol": ["type": "string",
                               "description": "Ticker for the cashtag — e.g. 'TSLA', 'NVDA'."]
                ],
                "required": ["symbol"]
            ]
        ]
    }

    private func xDiscussion(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let symbol = (arguments["symbol"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !symbol.isEmpty
        else { throw MCPToolError.invalidArgument("`symbol` must be a non-empty string") }
        return await runBridge(tool: .xDiscussion, args: ["symbol": .string(symbol)])
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
                // `Optional<Double>.none as Any` is rejected by
                // JSONSerialization — would throw and fail the whole
                // payload when ONE position's snapshot lookup failed.
                // Normalise nil → NSNull() per `marketValue`.
                "lastPrice": last.map { $0 as Any } ?? NSNull(),
                "costBasis": cost,
                "marketValue": last != nil ? market : NSNull(),
                "unrealizedPnL": pnl.map { $0 as Any } ?? NSNull()
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

    // MARK: - wick.methodology (Wicker analysis playbook)
    //
    // Surfaces TradingFloor's bundled markdown skills as MCP content so an
    // external agent (Claude Code / Codex / etc.) can READ our analysis
    // recipe and then orchestrate the steps itself — calling our data
    // tools at each stage and doing the LLM reasoning on its own side.
    // The point is the inverse of `wick.run_workflow`: we DON'T do the
    // analysis for them, but we DO hand them the playbook so they don't
    // have to invent one. ([[wick-business-model]] + see
    // `docs/why-no-mcp-run-workflow.md` for the design rationale.)

    private var methodologySpec: [String: Any] {
        [
            "name": "wick.methodology",
            "description": """
            Read Wicker's analysis playbook — the same step-by-step \
            instructions our internal Wicker agents follow. Call with no \
            arguments for the master recipe (full desk workflow + list of \
            available steps). Call with `name` ('fundamental-analysis', \
            'technical-analysis', 'sentiment-analysis', 'bull-bear-debate', \
            'full-desk-analysis', 'desk-analyst') to read that specific \
            step's instructions in full. Designed for an agent that wants \
            to drive the analysis itself using `wick.snapshot`, \
            `wick.candles`, etc. as data sources.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "Skill slug, e.g. 'fundamental-analysis'. Omit to get the master playbook + list of available skills."
                    ]
                ]
            ]
        ]
    }

    private func methodology(arguments: [String: Any]) async throws -> [[String: Any]] {
        // Lazy reload: skills are tiny markdown files, refreshing on each
        // call lets users override bundled skills by editing their copy in
        // `~/Library/Application Support/Wick/Skills/` without restarting
        // the MCP client.
        await skills.reload()
        let all = await skills.all()

        if let name = (arguments["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty
        {
            // Specific skill requested.
            guard let skill = await skills.skill(named: name) else {
                let known = all.map(\.name).sorted().joined(separator: ", ")
                return [[
                    "type": "text",
                    "text": "Unknown methodology `\(name)`. Available: \(known)."
                ]]
            }
            var lines: [String] = [
                "# \(skill.name)",
                "",
                "_\(skill.description)_",
                ""
            ]
            if !skill.triggers.isEmpty {
                lines.append("Triggers: \(skill.triggers.joined(separator: ", "))")
                lines.append("")
            }
            lines.append(skill.body)
            return [["type": "text", "text": lines.joined(separator: "\n")]]
        }

        // No name — return the master playbook.
        return [["type": "text", "text": masterPlaybook(skills: all)]]
    }

    /// The recipe the agent reads when it asks "how do I analyse a
    /// ticker with Wick?". Lists every skill it can drill into, but
    /// also explicitly spells out the calling convention: get data,
    /// then read methodology, then reason on the client side.
    private func masterPlaybook(skills: [Skill]) -> String {
        var lines: [String] = [
            "# Wicker Analysis Playbook",
            "",
            "Wick exposes data + methodology over MCP. You — the calling agent — drive the reasoning. Here's the canonical workflow our internal Wicker desk follows; you can run it step-by-step on your side.",
            "",
            "## Recommended steps",
            "",
            "1. **Pull the data.** Call `wick.snapshot(ticker)` for price action, technicals, fundamentals. Optionally `wick.candles(ticker, limit)` for raw OHLCV bars, `wick.holdings(symbol)` if the user already has a position, `wick.watchlist()` for context.",
            "2. **Read each analyst playbook** below and apply its method to the snapshot. Each one tells you what to look for and what shape of output to produce.",
            "3. **Run a bull-bear debate** using `bull-bear-debate` — debate your own analyst findings to surface counter-arguments.",
            "4. **Synthesize** a trade decision: `STRONG SELL | SELL | HOLD | BUY | STRONG BUY` with a position-size suggestion and 2-4 sentences of reasoning citing the strongest point on each side.",
            "5. **Risk-review** your decision — what's the downside, what tail risk would change your mind, what to monitor.",
            "",
            "## Available methodologies",
            ""
        ]
        for skill in skills {
            lines.append("- **`\(skill.name)`** — \(skill.description)")
        }
        lines.append("")
        lines.append("Call `wick.methodology(name: \"<slug>\")` to read any of these in full. The `full-desk-analysis` skill ties them all together.")
        lines.append("")
        lines.append("## What Wick does NOT do via MCP")
        lines.append("")
        lines.append("Wick deliberately does not expose a `wick.run_workflow` tool. The reasoning is yours — Wick supplies the data and the recipe. This avoids double-billing LLM inference (yours and ours), keeps the surface read-only, and lets you write your own analyst prompts on top of our data.")
        return lines.joined(separator: "\n")
    }

    // MARK: - wick.write_report (close the analysis loop)
    //
    // The external agent reads `wick.methodology`, pulls data through the
    // other tools, does its own reasoning, and lands at a rating + summary
    // + (optionally) a transcript of intermediate steps. This tool lets
    // it write that back into the user's Wick report history so the GUI
    // shows it next to reports generated by the in-app Wicker desk — same
    // shape, same persistence, same per-ticker history view. The Report
    // record carries a `source` field stamped `mcp:<client-name>` so the
    // UI can mark these visually distinct from Wicker desk runs without
    // hiding them.

    private var writeReportSpec: [String: Any] {
        [
            "name": "wick.write_report",
            "description": """
            Save the agent's analysis of a ticker into Wick's report history. \
            Produces the same shape Wicker's in-app desk run produces; the GUI \
            renders it in the user's Reports tab next to native Wicker reports. \
            Required: `ticker`, `rating` (STRONG_SELL/SELL/HOLD/BUY/STRONG_BUY), \
            `summary` (1-3 sentences with the bottom line). Optional but \
            recommended: `transcript` (your per-step findings as a list of \
            {role, content} entries — Fundamental Analyst, Technical Analyst, \
            Bull Researcher, Bear Researcher, Trader, Risk Manager), and \
            `position_percent` (target portfolio weight 0-100). Provide \
            `client` to identify yourself in provenance — shows up as \
            "mcp:<client>" in the report metadata.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ticker": ["type": "string",
                               "description": "Canonical symbol — e.g. '600519.SS', 'NVDA'."],
                    "rating": ["type": "string",
                               "enum": ["STRONG_SELL", "SELL", "HOLD", "BUY", "STRONG_BUY",
                                        "STRONG SELL", "STRONG BUY"],
                               "description": "Your final verdict."],
                    "summary": ["type": "string",
                                "description": "1-3 sentence bottom line."],
                    "transcript": [
                        "type": "array",
                        "description": "Optional per-step findings. Recommended roles: Fundamental Analyst, Technical Analyst, Sentiment Analyst, News Analyst, Bull Researcher, Bear Researcher, Trader, Risk Manager.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "role": ["type": "string"],
                                "content": ["type": "string"]
                            ],
                            "required": ["role", "content"]
                        ]
                    ],
                    "position_percent": [
                        "type": "number",
                        "description": "Target portfolio weight for this ticker, 0-100.",
                        "minimum": 0,
                        "maximum": 100
                    ],
                    "client": [
                        "type": "string",
                        "description": "Optional self-identification, e.g. 'claude-code' or 'codex'. Stamped into the report's `source` field as 'mcp:<client>'."
                    ]
                ],
                "required": ["ticker", "rating", "summary"]
            ]
        ]
    }

    private func writeReport(arguments: [String: Any]) throws -> [[String: Any]] {
        guard let ticker = (arguments["ticker"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !ticker.isEmpty
        else { throw MCPToolError.invalidArgument("`ticker` is required") }

        guard let ratingRaw = (arguments["rating"] as? String)?
            .replacingOccurrences(of: "_", with: " "),
              let rating = Rating.fromLabel(ratingRaw)
        else { throw MCPToolError.invalidArgument(
            "`rating` must be STRONG_SELL, SELL, HOLD, BUY, or STRONG_BUY")
        }

        guard let summary = (arguments["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty
        else { throw MCPToolError.invalidArgument("`summary` is required") }

        // Transcript: empty list is OK (the LLM may collapse all reasoning
        // into `summary`). Each entry must have role + content.
        let rawTranscript = (arguments["transcript"] as? [[String: Any]]) ?? []
        let messages: [AgentMessage] = rawTranscript.compactMap { entry in
            guard let role = entry["role"] as? String,
                  let content = entry["content"] as? String,
                  !role.isEmpty, !content.isEmpty
            else { return nil }
            return AgentMessage(role: role, content: content)
        }

        // Position size: percent (0-100) → fraction (0-1) for our model.
        let position: PositionSize? = {
            guard let pct = arguments["position_percent"] as? Double else { return nil }
            return PositionSize(targetWeight: pct / 100.0)
        }()

        let client = (arguments["client"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        let source = "mcp:\(client?.isEmpty == false ? client! : "external")"

        let now = Date()
        let report = Report(
            ticker: ticker,
            asOf: now,
            rating: rating,
            position: position,
            summary: summary,
            transcript: messages,
            generatedAt: now,
            source: source
        )
        SharedStore.appendReport(report)

        var lines: [String] = [
            "# Saved report — \(ticker)",
            "",
            "**Rating:** \(rating.label)"
        ]
        if let p = position {
            lines.append(String(format: "**Target position:** %.0f%%", p.targetWeight * 100))
        }
        lines.append("**Summary:** \(summary)")
        lines.append("**Source tag:** \(source)")
        lines.append("**Transcript entries:** \(messages.count)")
        lines.append("")
        lines.append("Stored in the user's Wick report history. They'll see it in the Reports tab.")

        return [["type": "text", "text": lines.joined(separator: "\n")]]
    }

    // MARK: - Snapshot rendering helpers

    private func render(_ s: MarketSnapshot) -> String {
        var lines: [String] = []
        if s.isStub {
            lines.append("> ⚠️ **Sample data** — no live provider is wired for `\(s.symbol)`. ")
            lines.append("> Non-CN/HK tickers fall back to a stub in this build. Configure FMP in Wick.app → Settings → Data to get real US numbers.")
            lines.append("")
        }
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
        let visibleFundamentals = s.fundamentals
            .filter { $0.key != StubMarketDataProvider.stubMarkerKey }
        if !visibleFundamentals.isEmpty {
            lines.append("")
            lines.append("**Fundamentals**")
            for (k, v) in visibleFundamentals.sorted(by: { $0.key < $1.key }) {
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
