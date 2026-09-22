# Codex OAuth in Wick

Implemented 2026-09-18 using the design of the user's `dsh-codex-adapter`
(`lib/auth.js`, `lib/credentials.js`, `lib/surface.js`, `lib/usage.js`) and its
pi-ai 0.85.1 OAuth/Responses provider. This supersedes the app-server proposal
in `research/codex-engine-integration.md`.

## Use

1. Open Settings → Provider, select Bring Your Own, and choose
   **Codex (ChatGPT subscription)** under Subscription.
2. Click **Sign in with ChatGPT**. Copy the one-time code, open the sign-in page,
   and complete authorization. Wick polls for completion. The attempt expires
   after ten minutes and can be cancelled.
3. Choose the quick and deep models. **Load model presets** loads a local list,
   as the adapter's pi-ai provider does; it is not an account model discovery
   call. Custom model IDs can be entered explicitly.
4. Chat in Wicker or run an analysis. These paths, including background
   session titles, use the Codex provider while it is
   selected. Other providers and their API keys remain available.
5. **Refresh usage** displays the plan and returned quota windows. Missing
   windows remain unknown. A failed refresh retains the last snapshot and its
   timestamp and does not remove the saved login.
6. **Sign out** deletes only Wick's Keychain credential and invalidates pending
   login/refresh work. It does not call global Codex logout or modify Codex files.

If device login is unavailable for the account, use **More options → Browser
sign-in (manual callback)**. After browser authorization, copy the full
`http://localhost:1455/auth/callback?...` URL into Wick. The browser may show a
connection error because Wick does not listen on that port. A callback must
match this login's state and redirect address; bare codes are not accepted.
This avoids adding an inbound network-server entitlement to the sandboxed app.

**More options → Import Codex credentials…** accepts Codex CLI's
`{ "tokens": { "access_token": ..., "refresh_token": ... } }` document,
usually `~/.codex/auth.json`. DSH adapter credential files are not supported.

Use Command-Shift-G in the picker to enter a hidden folder. Import copies the
credential once; it does not follow later source-file changes. Wick never
automatically reimports after sign-out. Independent sign-in is preferable for
regular use in multiple clients because copied rotating refresh tokens can
become stale in the other client. API-key-only Codex files are rejected.

## Implementation

- `CodexOAuthClient`: fixed OpenAI authentication endpoints; device-code flow,
  browser PKCE and callback validation, authorization-code exchange and refresh.
- `CodexCredentialStore`: actor with a single shared refresh task. Persisting a
  rotated credential is part of that task; all consumers see persistence errors.
  A revision invalidates old refresh/login results after replacement or logout.
- `CodexKeychain`: dedicated data-protection Keychain entry using
  `WhenUnlockedThisDeviceOnly`; update existing entries in place. Access/refresh
  tokens never go into UserDefaults, view bindings, diagnostics, or report data.
- `CodexOAuthProvider`: `POST https://chatgpt.com/backend-api/codex/responses`,
  OAuth bearer plus account header, `store: false`, `stream: true`. Maps existing
  text/image history to Responses messages. Reads SSE and requires a successful
  terminal event. A 401 triggers at most one retry with refreshed credentials.
- `CodexUsage`: the same `/backend-api/wham/usage` endpoint and window mapping as
  the adapter. The UI caches successful snapshots for sixty seconds unless
  explicitly refreshed. Old account results cannot overwrite a new account.

No new runtime dependency or entitlement is required. Wick still owns tool
execution, prompts and fixed-flow analyst orchestration. This implementation
does not include the DSH adapter's separate image-generation or web-search
clients. Existing Wick browser/data tools continue to work through ChatAgent.

The backend does not receive the existing generic `maxTokens`/`temperature`
fields, which are not assumed compatible with this subscription Responses
route. Responses are bounded while reading and incomplete output is rejected.

This is a direct OAuth backend integration, not the documented app-server
protocol or the ordinary API-key endpoint. It follows the referenced adapter's
behavior; it does not establish an OpenAI support or authorization guarantee
for arbitrary third-party distribution.

## Verification

Run `swift test --package-path TradingFloor --filter codex_`. Tests cover import
of Codex OAuth credentials and rejection of unsupported formats, PKCE callback
matching, device polling cancellation, concurrent refresh,
failed Keychain persistence, logout/account replacement races, request shape,
401 retry, streamed response completion and quota failures.

The tests use synthetic credentials and mocked HTTP, never the user's stored
DSH/Codex credentials. A real account authorization and live inference still
need to be exercised through the signed application.

The Xcode project is generated from `project.yml`; run `xcodegen generate` before
building. Full Xcode builds require the installed Xcode license to be accepted.
No license acceptance is performed by the integration.

Verification on 2026-09-18: all 186 TradingFloor tests passed (including twelve
Codex tests). A temporary SwiftPM executable target compiled and linked all
Wick Swift sources against local CandleKit, TradingFloor and MarkdownUI using
the Command Line Tools, with the installed SwiftUI macro plugin supplied
explicitly. This is a source-level integration check, not a signed Xcode app
build or an App Sandbox runtime test. `xcodebuild` stopped at the Xcode license
requirement; no real OAuth grant or inference request was sent.
