# Handoff — 2026-05-27 session

> Read this start-of-session so you don't re-litigate decisions. The
> previous session covered AI-report redesign, Keychain modernization,
> bundle-ID rebrand, Macro tab freeze fix, and lots of architectural
> Q&A. Below is the current state + what's queued next.

## Current branch state

- **Repo**: https://github.com/baixianger/Wick (private)
- **Branch**: `main`, fast-forwarded to remote
- **Latest commit on remote** (`864405e`): `wicker: document-waterfall chat (MarkdownUI), drop bubble, Xcode 26 settings`
- **Uncommitted local work** (not pushed):
  - `Wick/Data/Keychain.swift` — **rewrite to Apple best practices** (staged): adds `kSecAttrService="Wick"`, `kSecUseDataProtectionKeychain=true`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, OSStatus logging via `os_log`
  - `Wick/Data/AgentSettings.swift` — `adopt(...)` rewritten with closure (not `inout`) so `@Observable` didSet actually fires + Keychain.save runs
  - `Wick/Data/WatchlistStore.swift` — explicit `saveGroups()` calls in every mutation (didSet was being eaten by `@Observable`'s `_modify` accessor)
  - `Wick/Data/FredDataStore.swift` — equality-check guard before `sources[key] = .demo` (was causing infinite render loop on Macro tab when FRED key empty)
  - `Wick/App/ContentView.swift` — `customTickers` now persisted to UserDefaults `wick.customTickers.v1` via `PersistedTicker` struct; sidebar default width 200/260/360 above 240pt sparkline threshold
  - `Wick/Views/DetailView.swift` — removed `.inspector(isPresented:)` for history (was injecting duplicate toggle button); AITab body refactored to two-column HStack (left = report, right = vertical history timeline)
  - `Wick/Views/Tabs.swift` — `historyColumn(_:)` + `historyRow(_:)` added; auto-opens on entry when items exist
  - `.gitignore` — `WickServer/fred.md` added

**None of this is committed yet.** Suggested next git action: review the diff, run build once, commit as a single "infra: keychain hardening + observability fixes + AITab two-column" or split into 3 commits by topic.

## Bundle ID migration (just completed this session)

The `project.yml` has been changed from `ai.omika.wick` → `me.impai.wick`. Ran `xcodegen generate`, rebuilt, new sandbox container at `~/Library/Containers/me.impai.wick/`. **All UserDefaults / Keychain entries scoped to the OLD bundle are now orphaned and invisible** to the running app (sandbox-enforced access group mismatch). User-visible consequence: holdings, watchlists, settings, etc. all need to be re-populated under the new bundle. Re-import has been done for the 3 API keys via the DEBUG env-var path.

Old container at `~/Library/Containers/ai.omika.wick/` is **protected by containermanagerd** — cannot rm via CLI. Harmless residue; macOS will eventually GC it.

## API keys — all 4 imported into Keychain

Loaded via DEBUG env-var auto-adoption (`AgentSettings.adoptKeyFromEnvIfMissing()`):

| Key | Source on disk | Length |
|---|---|---|
| `OPENROUTER_API_KEY` | mac-mini `~/personal/langchain-MCP/.env` (ssh) | 73 |
| `FMP_API_KEY` | local `WickServer/fmp.md` (gitignored) | 32 |
| `FINNHUB_API_KEY` | local `WickServer/finnhub.md` (gitignored) | 40 |
| `FRED_API_KEY` | local `WickServer/fred.md` (gitignored) | 32 |

Provider settings (UserDefaults `me.impai.wick`):
- `tf.providerKind = openrouter`
- `tf.byo.openrouter.baseURL = https://openrouter.ai/api/v1`
- `tf.byo.openrouter.quickModel = deepseek/deepseek-v4-flash`
- `tf.byo.openrouter.deepModel = deepseek/deepseek-v4-pro`
- ⚠ The `deepseek-v4-pro` slug is **unverified** — first analysis run will tell us if it exists on OpenRouter; if not, switch via Settings → Refresh models.

**To re-import keys after another rebuild** (single line, copies values via env vars, never echoes them):
```bash
FINNHUB_API_KEY=$(head -1 /Users/baixianger/personal/Wick/WickServer/finnhub.md | tr -d '\r\n ') \
FMP_API_KEY=$(grep -oE 'apikey=[A-Za-z0-9]+' /Users/baixianger/personal/Wick/WickServer/fmp.md | head -1 | cut -d= -f2) \
FRED_API_KEY=$(grep -E '^[A-Za-z0-9]{16,}$' /Users/baixianger/personal/Wick/WickServer/fred.md | head -1) \
OPENROUTER_API_KEY=$(ssh mac-mini 'grep "^OPENROUTER_API_KEY=" ~/personal/langchain-MCP/.env | head -1 | cut -d= -f2-' | tr -d '"' "'" ' ') \
"/Users/baixianger/Library/Developer/Xcode/DerivedData/Wick-dwrwxmmfxmznbmepnsacdiwhouce/Build/Products/Debug/Wick.app/Contents/MacOS/Wick" &> /tmp/wick-launch.log & disown
```

## Pending work (priority order)

### NEXT (you'll start here): Document import → portfolio

Feature: drag-drop PDF/Excel/CSV into Wicker chat → LLM extracts transactions → confirm sheet → batch-insert into `HoldingsStore`. **Already designed, not coded yet.**

**Critical design constraint** (user explicitly insisted): de-duplication is automatic via `externalId` (broker Trade ID). Uploading the same statement twice → "0 new, N already imported". Uploading overlapping periods → only the net-new transactions surface.

**Test fixtures** (both real Saxo statements, both in `~/Downloads/` on this Mac):
- `TransactionBalance_21604458_2026-01-01_2026-05-26.pdf` → 18 stock txns (Jan-May 2026)
- `TransactionBalance_21604458_2025-10-01_2026-05-26.pdf` → 19 stock txns (Oct 2025-May 2026): same 18 as above + 1 extra (18-dec-2025 Novo Nordisk Buy 41 @ DKK 304.25, Trade ID 6517382994)

**Expected behavior table** (use as acceptance test):
| Sequence | Expected result |
|---|---|
| Upload Doc1 | 18 new, 0 skipped, 0 conflicts |
| Re-upload Doc1 | 0 new, 18 skipped (idempotent) |
| Upload Doc2 (after Doc1) | 1 new, 18 skipped |
| Re-upload Doc2 | 0 new, 19 skipped |

**Files to add**:
- `Wick/Data/DocumentImporter.swift` — protocol `extract(url:) async throws -> [ImportedTransaction]`
- `Wick/Data/LLMDocumentImporter.swift` — v1 sole implementation, PDFKit + LLM
- `Wick/Views/TransactionImportSheet.swift` — confirmation UI showing new/skipped/conflicts

**Files to modify**:
- `Wick/Data/Holdings.swift` — add `externalId: String?` + `source: Source` to `Holding`; add `importBatch(_:) -> ImportReport` method
- `Wick/Views/WickerView.swift` — 📎 button + drop target in composer
- Maybe `Wick/App/ContentView.swift` — auto-add imported tickers to `customTickers`

**Data model decisions** (don't relitigate):
- `Holding.externalId: String?` is the dedup primary key (broker Trade ID when known)
- `Holding.source: Source { case manual; case imported(broker, document) }` — provenance
- Symbol normalization: LLM converts to Yahoo Finance format (TSLA, AAPL, 00100.HK, NOVO-B.CO) and ALSO returns original instrument-name fallback
- Cash entries (Deposit / Withdrawal / Cash dividend / Withholding Tax) are filtered OUT — only stock Buy/Sell go to `HoldingsStore`
- Currency: keep instrument currency (price in USD/HKD/DKK), don't convert
- Fuzzy fallback dedup when `externalId == nil`: composite key `(symbol, date, side, abs(qty), abs(price))`

**Implementation order**:
1. `Holding` model extension + Codable v1→v2 migration (read old without externalId, default to nil)
2. `HoldingsStore.importBatch(_:)` + `ImportReport` struct
3. `LLMDocumentImporter` — PDFKit text extract + LLM prompt + JSON decode
4. `TransactionImportSheet` UI
5. WickerView composer drop zone + 📎 picker
6. End-to-end test with Doc1 + Doc2

**LLM prompt sketch** (don't pin to Saxo, must be broker-agnostic):
```
Extract stock transactions from this broker statement.
Rules:
  1. Only Buy/Sell stock transactions. SKIP cash, dividends, deposits, taxes, fees.
  2. Capture transaction ID (Trade ID / Order ID / Reference / Confirmation) as `externalId` when present.
  3. Normalize: symbols to Yahoo format, dates to ISO 8601, European decimals (1.234,56 → 1234.56), quantity always positive.
  4. Detect broker name from header/footer.

Return JSON:
{
  "broker": "<detected>",
  "transactions": [
    {"externalId": "...", "symbol": "TSLA", "name": "Tesla Inc.",
     "side": "sell", "date": "2026-05-26",
     "quantity": 12, "price": 433.26, "currency": "USD"}
  ]
}
```

Estimated ~10 hours of focused work.

### After file-import is done

**Migrate stores from UserDefaults to JSON files** (user agreed earlier):
- `HoldingsStore`, `WatchlistStore`, `ContentView.customTickers` currently use UserDefaults
- Move to `~/Library/Containers/me.impai.wick/Data/Library/Application Support/Wick/{holdings,watchlist,customTickers}.json`
- Pattern already established by `ChatStore` / `ReportHistoryStore` (see their `storeURL` static vars)
- Migration: on first launch, read old UserDefaults → write JSON → leave UserDefaults intact one cycle for safety, delete next launch
- Why: UserDefaults is for preferences, not user content; per Apple guidance + size limits + grep-ability

### Deferred (won't tackle next session unless asked)

- **Native structured output (Strategy A)**: extend `LLMProvider` protocol with `completeJSON(request, schema)`; Anthropic uses `tool_use` + `tool_choice`; OpenAI-compat uses `response_format: json_schema`. Layered on top of current prompt-based JSON envelope (Strategy B is foundation; A is opportunistic upgrade for providers that support it).
- **GovMacroProvider** (BLS API + Treasury Fiscal Data API): zero-key US macro fallback when FRED unavailable. Endpoints:
  - `https://api.bls.gov/publicAPI/v1/timeseries/data/{SERIES_ID}` (CPI: `CUUR0000SA0`, Unemployment: `LNS14000000`)
  - `https://api.fiscaldata.treasury.gov/services/api/fiscal_service/v2/accounting/od/daily_treasury_yield_curve_rates`
- **License server + Paddle/LemonSqueezy** for dual-distribution monetization
- **MCP server + Homebrew CLI** for power-user tier (dual MAS / direct distribution)

## Important architectural pitfalls learned this session

### `@Observable` macro + `didSet` + `inout` = silent NOP

Three different bugs all rooted in the same pattern. When `@Observable` rewrites a stored property, its `_modify` accessor doesn't fire the wrapper-level `didSet`. **Anything that mutates an `@Observable` property via `inout` parameter, subscript-assign, array `.append`, etc. will skip didSet.**

Confirmed cases:
1. `WatchlistStore.groups.append(...)` — fix: explicit `saveGroups()` in each mutation method
2. `AgentSettings.adopt(env[...], into: &slot)` — fix: closure-based setter (`set: { slot = $0 }`)
3. `FredDataStore.sources[key] = .demo` written every render — equality guard before write to avoid infinite invalidate loop

**Rule**: don't depend on `didSet` for persistence side effects in `@Observable` classes. Call save/persist methods explicitly in every mutation entry point.

### macOS sandbox + Keychain access groups

Sandboxed app's Keychain items are written to access group `<TEAM>.<BUNDLE>` (e.g. `<TEAM>.me.impai.wick`). The `security` CLI on the user's behalf **cannot see them** (different access group). Don't try to verify Keychain state via `security find-generic-password` — verify via running the app and looking at Settings UI.

### `.inspector(isPresented:)` auto-injects toolbar toggle

macOS 14+ behavior: `.inspector(isPresented: $x)` adds a system toggle button to the detail-pane toolbar. No documented API to suppress (`.toolbar(removing: .toggleInspector)` doesn't exist as of macOS 26 SDK). Either accept the auto toggle OR don't use `.inspector` (custom HStack column instead — what we did for AITab history).

## Useful one-liners

```bash
# Rebuild + relaunch with all 4 keys (re-import via DEBUG adopt)
xcodegen generate   # only if project.yml changed
# (then BuildProject via Xcode MCP, then kill+launch via env-var script above)

# Inspect current state
defaults read me.impai.wick | head -30   # all UserDefaults
ls ~/Library/Containers/me.impai.wick/Data/Library/Application\ Support/Wick/   # JSON stores
defaults read ai.omika.wick 2>&1 | head -3   # legacy bundle; should fail / be empty

# Test sample fixtures (in user's Downloads)
ls -la ~/Downloads/TransactionBalance_*.pdf
```

## Open questions to ask user at start of next session

1. ~~File import scope (PDF / CSV / Excel / Image all v1?)~~ — assumed all via LLM
2. ~~Symbol normalization (auto vs manual)?~~ — auto via LLM with manual edit fallback in sheet
3. ~~Dedup definition?~~ — Trade ID primary, composite fallback
4. ~~Auto-add unseen tickers to sidebar?~~ — yes
5. **Commit cadence**: split the 7 uncommitted files into 3 logical commits, or one big "infra hardening" commit?
6. **deepseek-v4-pro slug**: verify exists on OpenRouter before user triggers first AI Desk run, otherwise it'll 404
