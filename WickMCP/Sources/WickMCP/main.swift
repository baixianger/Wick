import Foundation
import TradingFloor

// Entry point. Stays tiny on purpose — the moving parts live in
// `MCPServer` (transport) and `ToolHost` (capabilities). main()'s job is
// to assemble the data-provider chain the host MCP client is going to
// query through.
//
// Step-1 chain mirrors the *shape* WickServer + Wick AgentRuntime use,
// but skipped the BYO LLM keys and the news / macro decorators — Step 1
// only exposes `wick.snapshot`, which doesn't need an LLM. CN tickers go
// through EastMoney + EastMoneyFinancialProvider (both key-free). US /
// international tickers fall back to `StubMarketDataProvider` for now;
// Step 2 will swap in FMP via App-Group-shared keychain.
//
// Logging policy: NEVER print to stdout. Stdout is reserved for the MCP
// stream — any stray write there corrupts the JSON-RPC frame and the
// client disconnects. All diagnostics go through `log(_:)` (stderr).

log("starting wick-mcp 0.1.0")
// One-time App Group probe — confirms the helper actually shares state
// with Wick.app. Surfaces as a stderr line during dev / debugging so a
// misconfigured signing pass is easy to spot. The check requires the
// sandbox to be fully initialized (which only happens once the embedded
// Info.plist is in place — see CREATE_INFOPLIST_SECTION_IN_BINARY in
// project.yml); without that the binary trapped during sandbox init
// before this probe ever ran.
if SharedStore.isAppGroupAvailable {
    log("shared App Group container reachable — holdings/watchlist will sync with Wick.app")
} else {
    log("App Group not provisioned — holdings/watchlist will be empty until Wick.app + helper share the same Team ID + group.me.impai.wick entitlement")
}

let eastMoney = EastMoneyMarketDataProvider()
let usFallback: any MarketDataProvider = StubMarketDataProvider()
var chain: any MarketDataProvider = MarketRouter(
    cn: eastMoney,
    fallback: usFallback
)
chain = EastMoneyFinancialProvider(base: chain)

let tools = ToolHost(market: chain, eastMoney: eastMoney)
let server = MCPServer(tools: tools)
await server.run()

log("stdin closed, exiting")
