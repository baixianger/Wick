# Wick

Native macOS stocks & portfolio monitor — built on [CandleKit](https://github.com/baixianger/CandleKit).

Sidebar watchlists, live Yahoo Finance data, candlestick + line charts with technical indicators, holdings & P/L, news, all rendered with iOS 26 / macOS 26 Liquid Glass.

## Getting started

```bash
# 1. Generate the Xcode project
brew install xcodegen   # if you don't have it
xcodegen generate

# 2. Open and run
open Wick.xcodeproj
```

CandleKit is referenced as a **local SPM package** at `../CandleKit/` during development. Before release, the dependency is switched to a tagged version.

## Codex subscription login

In **Settings → Provider → Bring Your Own**, choose **Codex (ChatGPT subscription)**.
Select **Sign in with ChatGPT**, open the sign-in page, and enter the displayed
one-time code. No Codex CLI, app-server, Node.js, or OpenAI API key is required.
Wick keeps running its own chat/tool loop and analysis workflow.

**More options** provides browser login with a manually pasted callback URL and
import of a Codex CLI `auth.json` containing OAuth tokens. Credentials are
stored in Wick's Keychain entry. **Sign out** removes that entry; it does not
delete the source application's login. Model presets are editable and do not
guarantee availability on your account.

See [OAuth setup and implementation](docs/codex-oauth.md) for login details,
the scope of this integration, and verification instructions.

## Layout

```
Wick/
├── App/         # App entry + window + appearance
├── Data/        # Stores: holdings, watchlist, live-data cache, tickers
├── Design/      # Liquid Glass helpers, flat pickers, shared UI bits
├── Views/       # Sidebar, detail tabs, portfolio, holding editor, etc.
└── Resources/   # Info.plist, entitlements, asset catalog
```

## License

Proprietary. All rights reserved.
