// swift-tools-version: 6.0
import PackageDescription

// WickMCP — stdio MCP (Model Context Protocol) server that exposes Wick's
// market-data / Wicker-workflow surface as tools any MCP client (Claude
// Code, Codex CLI, MCP Inspector) can drive over stdin/stdout.
//
// Step 1 ships a single tool: `wick.snapshot(ticker)`. Later phases add the
// rest of the Wicker workflow steps (run_workflow / fundamental_analyst /
// holdings / watchlist).
//
// Deliberately mirrors `WickServer`'s structure — sibling SPM package next
// to it — so the same TradingFloor substrate powers both surfaces.
let package = Package(
    name: "WickMCP",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../TradingFloor"),
    ],
    targets: [
        .executableTarget(
            name: "WickMCP",
            dependencies: [
                .product(name: "TradingFloor", package: "TradingFloor"),
            ]
        ),
        .testTarget(
            name: "WickMCPTests",
            dependencies: [
                "WickMCP",
                .product(name: "TradingFloor", package: "TradingFloor"),
            ]
        ),
    ]
)
