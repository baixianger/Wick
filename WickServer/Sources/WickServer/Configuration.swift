import Foundation

/// Server config from the environment — secrets never live in code or the
/// image. These keys are OURS (the shared service pays), unlike the app's BYO.
struct Configuration: Sendable {
    let anthropicKey: String?       // 1st choice
    let openRouterKey: String?      // 2nd choice (cheap/free models)
    let openRouterModel: String?    // default: a free DeepSeek model
    let fmpKey: String?
    let finnhubKey: String?
    let fredKey: String?
    let port: Int
    let maxWorkers: Int
    let storeDirectory: URL
    /// A-shares + Hong Kong via EastMoney's open endpoints. No key needed,
    /// so the default is ON; set `ENABLE_CN_MARKETS=0` to disable in
    /// restricted deployments (e.g. regions that block EastMoney).
    let enableChinaMarkets: Bool

    static func fromEnvironment() -> Configuration {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
        let dir = value("REPORT_STORE_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: "./report-cache", isDirectory: true)
        let enableCN: Bool = {
            guard let raw = value("ENABLE_CN_MARKETS")?.lowercased() else { return true }
            return !["0", "false", "no", "off"].contains(raw)
        }()
        return Configuration(
            anthropicKey: value("ANTHROPIC_API_KEY"),
            openRouterKey: value("OPENROUTER_API_KEY"),
            openRouterModel: value("OPENROUTER_MODEL"),
            fmpKey: value("FMP_API_KEY"),
            finnhubKey: value("FINNHUB_API_KEY"),
            fredKey: value("FRED_API_KEY"),
            port: value("PORT").flatMap(Int.init) ?? 8080,
            maxWorkers: value("MAX_WORKERS").flatMap(Int.init) ?? 4,
            storeDirectory: dir,
            enableChinaMarkets: enableCN
        )
    }
}
