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
