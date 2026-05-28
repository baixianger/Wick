# WickMCP — stdio MCP server bundled inside Wick.app

`wick-mcp` is a small Swift CLI that exposes Wick's market-data surface
as **[Model Context Protocol](https://modelcontextprotocol.io)** tools.
Drop it into Claude Code, Codex CLI, MCP Inspector, or any other MCP
client and your agent can call `wick.snapshot`, `wick.candles`,
`wick.holdings`, `wick.watchlist`, `wick.portfolio` directly — using
your own LLM (and your own API costs).

The binary ships **inside `Wick.app/Contents/MacOS/wick-mcp`** in the
Mac App Store build. Installing Wick gates access to the helper; once
installed, the helper runs as its own short-lived sandboxed subprocess
spawned by the MCP client — **Wick.app does not need to be open**.

## Why this exists

Two things wired together:

1. **MAS distribution gate** — users must purchase / download Wick from
   the App Store to get the helper. Single distribution channel; same
   subscription / licensing logic as the GUI.
2. **External-agent ergonomics** — Claude Code and Codex CLI already
   ship a great chat-and-tool surface. Rather than rebuild that inside
   Wick, we expose Wick's *data* and let users drive their own agent
   through the tools.

The agentic prior work in `TradingFloor` (Fundamental / Technical /
Sentiment / News analysts → Bull/Bear debate → Trader → Risk) is still
embedded in Wick.app for users who want a single-click report. MCP is
the alternative for power users who'd rather drive each step
themselves from their existing AI workflow.

## Architecture

```
Claude Code  / Codex CLI  / MCP Inspector
   │
   │   stdio (JSON-RPC 2.0)
   ▼
/Applications/Wick.app/Contents/MacOS/wick-mcp     (sandboxed, signed)
   │
   ├─ EastMoneyMarketDataProvider        (A-share / HK, no API key)
   ├─ EastMoneyFinancialProvider         (Decorator — F10 financials)
   ├─ StubMarketDataProvider (fallback)  (US tickers, Step 1 placeholder)
   │
   └─ SharedStore (group.me.impai.wick)  ← Wick.app writes here
       ├─ holdings  (transactions)
       └─ watchlist (groups)
```

The helper is its own SPM package (`WickMCP/`) that depends on the
in-repo `TradingFloor/` package, the same way `WickServer/` is a peer
package. xcodegen weaves it into the Xcode project as a second target
of type `tool`; a Copy Files build phase on the `Wick` target copies
the helper into `Wick.app/Contents/MacOS/wick-mcp` so it ships inside
the bundle.

## Tools

| Tool                  | Arguments                  | What it returns |
|-----------------------|----------------------------|------|
| `wick.snapshot`       | `ticker: string`           | Last price, technicals (RSI/MACD/SMA), fundamentals (PE, PB, ROE, 营收 YoY, 净利 YoY, 报告期, …) |
| `wick.candles`        | `ticker, limit?`           | Up to N (≤300) daily OHLCV bars + change-% + amount, oldest → newest |
| `wick.holdings`       | `symbol?` (filter)         | Transactions from the App-Group container, with net-position summary |
| `wick.watchlist`      | _none_                     | All watchlist groups + their symbols |
| `wick.portfolio`      | _none_                     | Net positions × latest price → cost / market value / P&L (parallel snapshots) |
| `wick.methodology`    | `name?`                    | Wicker's analysis playbook. No args → master recipe + list of available steps. With `name` (`fundamental-analysis`, `technical-analysis`, `sentiment-analysis`, `bull-bear-debate`, `full-desk-analysis`, `desk-analyst`) → that step's full instructions. **Read this first** if you want to drive a full analysis. |
| `wick.write_report`   | `ticker, rating, summary, transcript?, position_percent?, client?` | Save your analysis back into Wick's report history. Same on-disk shape as the in-app Wicker desk produces; appears in the user's Reports tab next to native reports. Stamped with `source: mcp:<client>` so the UI can distinguish "you ran it" from "your agent wrote it back". |

Each tool returns two content blocks: a Markdown digest the LLM reads
naturally, and a fenced ```json``` payload a programmatic caller can
parse.

A-share suffixes (`.SS` / `.SZ`) and Hong Kong (`.HK`) are routed
through EastMoney's open `push2his` / `datacenter` endpoints. US
tickers route to a stub provider on this Step-1 build; FMP integration
arrives once the App-Group-shared keychain plumbing lands.

## Wiring it into Claude Code

After installing Wick, open **Wick → Settings → MCP** and copy the
JSON snippet (there's a button). Paste it into `~/.claude.json`:

```json
{
  "mcpServers": {
    "wick": {
      "type": "stdio",
      "command": "/Applications/Wick.app/Contents/MacOS/wick-mcp"
    }
  }
}
```

Then in any Claude Code session:

```bash
claude mcp list                  # should show: wick: ✓ Connected
```

Ask the agent things like:

> Show me the last 30 days of 600519.SS candles and tell me where the
> reversal hit.

> What's the unrealized P/L on my current portfolio?

> Compare the income-statement YoY between 0700.HK and 09988.HK.

Claude Code spawns `wick-mcp` once per session, holds the stdio pipe
open, and the helper sits idle (~2 MB RSS) between tool calls. When
the session closes, the helper exits.

## Wiring it into Codex CLI

Same pattern — Codex's MCP config is similarly shaped. See
[Codex MCP docs](https://developers.openai.com/codex/mcp) for the
exact file location.

## Permissions / sandbox

The helper carries:

- `com.apple.security.app-sandbox` — MAS requirement
- `com.apple.security.network.client` — outbound HTTPS to EastMoney
- `com.apple.security.application-groups: [group.me.impai.wick]` —
  shares holdings / watchlist with Wick.app

It does **not** declare:

- `network.server` — doesn't listen on any port (stdio only)
- `files.user-selected.read-only` — never touches user files
- inbound XPC — no other process talks to it except the spawning MCP client

## Dev / build instructions

The package builds standalone too — useful for iterating on tools
without rebuilding the GUI app:

```bash
cd WickMCP
swift build               # builds .build/arm64-apple-macosx/debug/WickMCP
swift run WickMCP         # for hand-fed JSON-RPC smoke tests
```

To verify end-to-end with a hand-crafted request:

```bash
cat <<'EOF' | swift run WickMCP
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wick.snapshot","arguments":{"ticker":"600519.SS"}}}
EOF
```

For the bundled (sandboxed, App-Group-entitled) build:

```bash
xcodegen generate
xcodebuild -project Wick.xcodeproj -scheme Wick \
           -configuration Debug -destination 'platform=macOS' \
           -allowProvisioningUpdates build

# Locate the bundle, then poke the bundled helper directly:
BUNDLED=$(find ~/Library/Developer/Xcode/DerivedData/Wick-* \
           -path '*/Build/Products/Debug/Wick.app/Contents/MacOS/wick-mcp' \
           -type f | head -1)
echo $BUNDLED
```

## License

Proprietary. Same as Wick — see the root `README.md`.
