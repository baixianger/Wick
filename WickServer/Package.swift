// swift-tools-version: 6.0
import PackageDescription

// WickServer — the HTTP shell around TradingFloor's ReportService.
// Pure server-side Swift (Hummingbird + SwiftNIO); runs on Linux/containers.
// Deliberately does NOT depend on CandleKit — that pulls SwiftUI, which won't
// build on Linux. The server fetches its own data (Foundation-only) instead.
let package = Package(
    name: "WickServer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../TradingFloor"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "WickServer",
            dependencies: [
                .product(name: "TradingFloor", package: "TradingFloor"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
    ]
)
