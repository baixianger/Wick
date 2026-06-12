import Foundation
import TradingFloor

/// Wicker's **portfolio-write tools** — the app-side `AgentTool` conformers that
/// let the chat agent read and mutate the user's holdings (持仓). They mirror the
/// `web.*` bridge exactly: `HoldingsStore` is `@MainActor @Observable`, an
/// `AgentTool` is `Sendable` and its `call` runs off any actor, so we bridge with
/// `@Sendable` async closures captured at registration time (`PortfolioToolDriver`)
/// that hop to `@MainActor` and call the store. The tools hold the closures, never
/// the store, so the `Sendable` conformance stays clean.
///
/// Registered into the SAME `ToolRegistry` as `MarketDataTool` / `web.*`, so from
/// `ChatAgent`'s perspective `portfolio.*` is indistinguishable from any other
/// tool. Wiring happens in `AgentRuntime.attachPortfolio(_:)`, called from
/// `ContentView` where the live `HoldingsStore` exists.
///
/// **Write semantics.** `portfolio.add` appends a transaction (buy/sell lot) —
/// the store models a transaction ledger, not a single position, so repeated buys
/// accumulate and `positions()` nets them. The action lands immediately in the
/// user-visible Portfolio page (the panel the user is looking at), which is the
/// MVP visibility guardrail; a per-write confirmation hook is a separate hardening
/// step (see the WebTools TODO + task #43).

/// The main-actor bridge a `PortfolioTool` calls to reach the holdings store.
/// `AgentRuntime` builds these over the live `HoldingsStore` at registration.
struct PortfolioToolDriver: Sendable {
    /// Append a transaction; returns a human-readable confirmation line.
    var add: @Sendable (_ tx: PortfolioAddRequest) async -> String
    /// Current netted positions, formatted for the model to read back.
    var list: @Sendable () async -> String
    /// Raw transaction ledger (optionally filtered by symbol), each row
    /// carrying its `id` so the model can reference a specific lot to remove.
    var transactions: @Sendable (_ symbol: String?) async -> String
    /// Delete one transaction by its `id` (a UUID string from `transactions`);
    /// returns what was removed, or a not-found note.
    var remove: @Sendable (_ id: String) async -> String
}

/// Decoded arguments for `portfolio.add`, normalised into store types by the
/// tool before it hits the driver.
struct PortfolioAddRequest: Sendable {
    var symbol: String
    var name: String
    var side: HoldingSide
    var quantity: Double
    var price: Double
    var currency: String
    var date: Date
}

// MARK: - portfolio.add

/// Append a buy/sell transaction to the user's holdings.
struct PortfolioAddTool: AgentTool {
    let driver: PortfolioToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "portfolio.add",
            description: "Record a transaction in the user's portfolio (持仓): a buy or sell of a "
                + "quantity of a symbol at a price. Appends a lot to the ledger — repeated buys "
                + "accumulate and net against sells. Use this when the user asks to log/add a trade "
                + "or a position. Confirm the details with the user first if any are ambiguous.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "symbol":   { "type": "string", "description": "Ticker symbol, e.g. AAPL, 600519.SS, 0700.HK" },
                "name":     { "type": "string", "description": "Company / instrument name; defaults to the symbol if unknown." },
                "side":     { "type": "string", "enum": ["buy", "sell"], "description": "Trade direction." },
                "quantity": { "type": "number", "description": "Number of shares/units (positive)." },
                "price":    { "type": "number", "description": "Per-unit trade price in `currency`." },
                "currency": { "type": "string", "description": "ISO currency code, e.g. USD, CNY, HKD. Defaults to USD." },
                "date":     { "type": "string", "description": "ISO-8601 trade date (YYYY-MM-DD); defaults to today." }
              },
              "required": ["symbol", "side", "quantity", "price"]
            }
            """)
    }

    private struct Args: Decodable {
        let symbol: String
        let name: String?
        let side: String
        let quantity: Double
        let price: Double
        let currency: String?
        let date: String?
    }

    func call(arguments: Data) async throws -> String {
        let a = try JSONDecoder().decode(Args.self, from: arguments)
        guard let side = HoldingSide(rawValue: a.side.lowercased()) else {
            return "Error: side must be \"buy\" or \"sell\" (got \"\(a.side)\")."
        }
        guard a.quantity > 0 else { return "Error: quantity must be positive." }
        guard a.price >= 0 else { return "Error: price must be non-negative." }
        let symbol = a.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbol.isEmpty else { return "Error: symbol is required." }

        let date = a.date.flatMap(Self.parseDate) ?? .now
        let req = PortfolioAddRequest(
            symbol: symbol,
            name: a.name?.isEmpty == false ? a.name! : symbol,
            side: side,
            quantity: a.quantity,
            price: a.price,
            currency: (a.currency?.isEmpty == false ? a.currency! : "USD").uppercased(),
            date: date)
        return ToolResultBounding.bound(await driver.add(req))
    }

    /// Accept a bare `YYYY-MM-DD` (most common from the model) or a full
    /// ISO-8601 timestamp.
    private static func parseDate(_ s: String) -> Date? {
        if let d = isoDate.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        return iso.date(from: s)
    }
    private static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - portfolio.list

/// Read the user's current netted positions.
struct PortfolioListTool: AgentTool {
    let driver: PortfolioToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "portfolio.list",
            description: "List the user's current portfolio (持仓) positions: per-symbol net quantity, "
                + "average buy price, and transaction count. Use this to answer questions about what "
                + "the user holds before adding or analysing positions.",
            parametersJSONSchema: """
            { "type": "object", "properties": {} }
            """)
    }
    func call(arguments: Data) async throws -> String {
        ToolResultBounding.bound(await driver.list())
    }
}

// MARK: - portfolio.transactions

/// List the raw transaction ledger (each lot WITH its `id`) so the model can
/// reference a specific row to remove. `portfolio.list` nets by symbol and
/// hides ids; this is the addressable view.
struct PortfolioTransactionsTool: AgentTool {
    let driver: PortfolioToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "portfolio.transactions",
            description: "List individual portfolio (持仓) transactions WITH their ids — optionally "
                + "filtered to one symbol. Each row shows id, symbol, side, quantity, price, currency, "
                + "and date. Call this to find the id of a lot before removing or correcting it.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "symbol": { "type": "string", "description": "Optional ticker to filter to, e.g. AAPL; omit for all." }
              }
            }
            """)
    }
    private struct Args: Decodable { let symbol: String? }
    func call(arguments: Data) async throws -> String {
        let symbol = (try? JSONDecoder().decode(Args.self, from: arguments))?.symbol
        let normalized = symbol?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolResultBounding.bound(
            await driver.transactions(normalized?.isEmpty == false ? normalized : nil))
    }
}

// MARK: - portfolio.remove

/// Delete one transaction by its `id`. Destructive — the tool description tells
/// the model to confirm with the user first; the result echoes what was removed
/// so it lands visibly in the conversation.
struct PortfolioRemoveTool: AgentTool {
    let driver: PortfolioToolDriver
    var spec: ToolSpec {
        ToolSpec(
            name: "portfolio.remove",
            description: "Delete ONE transaction from the user's portfolio (持仓) by its id (get ids from "
                + "portfolio.transactions). This is destructive and cannot be undone — confirm the exact "
                + "lot with the user before calling. Returns what was removed, or a not-found note.",
            parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "id": { "type": "string", "description": "The transaction id (UUID) from portfolio.transactions." }
              },
              "required": ["id"]
            }
            """)
    }
    private struct Args: Decodable { let id: String }
    func call(arguments: Data) async throws -> String {
        let id = try JSONDecoder().decode(Args.self, from: arguments).id
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return "Error: id is required (get it from portfolio.transactions)." }
        return ToolResultBounding.bound(await driver.remove(id))
    }
}

// MARK: - Bundle

enum PortfolioTools {
    /// The `portfolio.*` tools, built over a driver. `AgentRuntime` calls this
    /// with a driver that forwards to the live `HoldingsStore`, then registers
    /// the result into the shared `ToolRegistry`.
    static func all(driver: PortfolioToolDriver) -> [any AgentTool] {
        [
            PortfolioAddTool(driver: driver),
            PortfolioListTool(driver: driver),
            PortfolioTransactionsTool(driver: driver),
            PortfolioRemoveTool(driver: driver),
        ]
    }

    /// Names — used to UNregister when retracting (registry keyed by `spec.name`).
    static let names = ["portfolio.add", "portfolio.list",
                        "portfolio.transactions", "portfolio.remove"]
}
