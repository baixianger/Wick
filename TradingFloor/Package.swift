// swift-tools-version: 6.0
import PackageDescription

// TradingFloor — a native Swift multi-agent stock-analysis engine.
//
// Architecture inspired by TauricResearch/TradingAgents (Apache-2.0):
// a simulated trading desk where specialist LLM agents analyse a ticker,
// bull/bear researchers debate, and a trader + risk pass produce a verdict.
//
// Deliberately depends on NOTHING but Foundation. The two things an agent
// needs from the outside world — an LLM and market data — arrive through
// the `LLMProvider` and `MarketDataProvider` protocols. The host app (Wick)
// supplies concrete implementations (the user's chosen LLM; CandleKit/Yahoo
// data). That keeps this package pure, unit-testable, and reusable.
let package = Package(
    name: "TradingFloor",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TradingFloor", targets: ["TradingFloor"]),
    ],
    targets: [
        .target(
            name: "TradingFloor",
            resources: [
                // Skill markdowns ship with the module so `SkillRegistry` can
                // read them via `Bundle.module` at runtime. `.copy` keeps them
                // verbatim (no localization processing for `.md`).
                .copy("Resources/Skills"),
            ]
        ),
        .testTarget(name: "TradingFloorTests", dependencies: ["TradingFloor"]),
    ]
)
