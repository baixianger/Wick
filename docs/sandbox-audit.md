# `wick-mcp` Sandbox Audit

**Date:** 2026-05-28
**Binary under review:** `Wick.app/Contents/MacOS/wick-mcp`
**Auditor:** Internal (paired with the SandboxRedTeamTests test suite in `WickMCP/Tests/`).
**Trigger:** MAS submission prep — wanted to confirm the bundled helper can't be tricked into expanding its blast radius.

## Threat model

The helper is launched as a child process by external MCP clients (Claude
Code, Codex CLI, MCP Inspector). Those clients send arbitrary tool
arguments. We assume:

- **Trusted:** the user's local MCP client (Claude Code is signed by
  Anthropic; same threat posture as VS Code or any other dev tool).
- **Semi-trusted:** the user's LLM. It can choose what arguments to pass
  to `wick.snapshot(ticker:...)` etc., but only within the JSON-Schema
  we advertise.
- **Untrusted:** the network responses from EastMoney / FMP / Anthropic.
- **Untrusted:** any data already in `SharedStore` (user could have a
  corrupt holdings file we choke on; we should degrade gracefully).

## Declared entitlements (and why)

| Key | Value | Purpose |
|---|---|---|
| `com.apple.security.app-sandbox` | `true` | Required by MAS for every embedded binary |
| `com.apple.security.network.client` | `true` | Outbound HTTPS to EastMoney / FMP / Anthropic |
| `com.apple.security.application-groups` | `[group.me.impai.wick]` | Read holdings / watchlist that Wick.app writes |

## Capabilities we *don't* claim

The helper does NOT carry any of:

```
com.apple.security.network.server                       # no listening sockets — stdio only
com.apple.security.files.user-selected.read-write       # no file pickers
com.apple.security.files.downloads.read-write           # no ~/Downloads access
com.apple.security.files.bookmarks.app-scope            # no security-scoped bookmarks
com.apple.security.device.audio-input                   # no mic
com.apple.security.device.camera                        # no camera
com.apple.security.personal-information.location        # no location
com.apple.security.personal-information.contacts        # no contacts
com.apple.security.scripting-targets                    # no AppleScript out
com.apple.security.temporary-exception.*                # no holes
```

`SandboxRedTeamTests.helper_advertises_only_expected_entitlements()`
enforces this. If anyone adds one of those to fix a bug, the test
fails before the change can ship.

## Attack-surface walk-through

### 1. Arbitrary file write

The helper has no `files.user-selected.read-write` or `temporary-
exception` entitlements, so writes outside the sandbox container fail
at the kernel level. Inside its own container, the helper does ONLY:

- Implicit `UserDefaults` writes via `SharedStore` (we never `setObject`
  outside `SharedStore.Keys.*`; checked by reading the source).
- Implicit logging via `FileHandle.standardError.write` — stderr is
  inherited from the parent MCP client, not a file on disk.

`SandboxRedTeamTests.helper_source_does_not_touch_arbitrary_filesystem_paths()`
greps the source for string literals beginning with `/Users/` / `/tmp/`
/ `/Library/` etc. and fails the build if any leaks in.

### 2. Listening on a TCP port

`com.apple.security.network.server` is denied. Any call to
`bind(2)` / `listen(2)` returns `EPERM` (the sandbox kernel extension
blocks it). The helper has no code path that attempts this — it's a
stdio server only.

### 3. Keychain access

The helper has no `keychain-access-groups` entitlement, so it can only
read items it created itself (none today). Future work: when
`wick.run_workflow` needs the user's LLM API key, we'll add a shared
Keychain group entitled to BOTH Wick.app and wick-mcp; that change
will require updating this audit.

### 4. AppleScript / Automation

No `scripting-targets` entitlement → can't drive other apps. Can't
sneakily call into Mail, Messages, Calendar via AppleScript bridge.

### 5. Cross-process inspection

`get-task-allow` is `true` in Debug builds (Xcode default) so the
helper can be attached by lldb during development. **For Release builds
this must flip to `false`** — the project.yml currently doesn't
override the default, so this is a TODO before MAS submission. The
test suite will need a Release-mode counterpart to verify this.

## Network egress

`network.client` is broad — once granted, the helper can connect to
**any** host. We do not currently constrain egress per-host. Three
real destinations the code reaches:

1. `push2his.eastmoney.com` / `push2delay.eastmoney.com` (CN market data, no key)
2. `datacenter-web.eastmoney.com` / `datacenter.eastmoney.com` (CN financials)
3. (future) `api.anthropic.com` once `wick.run_workflow` lands

A hostile MCP client could craft a `ticker` argument that causes us to
encode it into a URL path or query string. We sanity-check this by:

- All EastMoney URLs are built via `URLComponents` + `queryItems`, so
  ticker text is URL-encoded — no SQLi / header-injection vector.
- Tickers that don't match `CNSymbol.parse()` (returns nil for non-CN)
  short-circuit before any HTTP call.

Risk: if a future tool accepted a free-form URL or hostname as input,
that becomes an SSRF vector against `network.client`. Mitigation:
always validate that inputs map to one of our known providers via a
typed wrapper (`CNSymbol.parse`, future `SymbolKind.parse`), never
take a raw URL.

## Findings summary

| Finding | Severity | Status |
|---|---|---|
| `get-task-allow=true` in Debug builds | Informational (debug-only) | TODO Release-mode flip + Release-mode test |
| Keychain entitlement absent | OK | Acceptable until run_workflow lands |
| Network egress not host-restricted | Low | Acceptable; all current destinations URL-encoded |
| No file-system access outside App Group | OK | Enforced by `app-sandbox` |
| No listening sockets | OK | Enforced by absence of `network.server` |
| All entitlements minimal | OK | Test asserts the set |

## Re-audit triggers

This audit needs a redo whenever:

- A new entitlement is added (the test will fail loud first).
- A new tool consumes user-provided strings as URLs / hosts / file paths.
- The helper starts using Keychain.
- Release-mode signing settings are configured.

## Notes for App Review

If MAS reviewers ask why the .app bundles a CLI:

> `wick-mcp` is a Model Context Protocol server (modelcontextprotocol.io)
> exposing read-only access to the user's locally-stored holdings and
> watchlist so they can integrate with their own AI assistant (Claude
> Code, Codex CLI, etc.). It is sandboxed, talks stdio JSON-RPC only,
> shares state with Wick.app via an App Group, and never listens on a
> port. The user must explicitly add it to their MCP client config to
> activate it — Wick does not install daemons or auto-launch it.
