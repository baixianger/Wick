import Foundation

/// One news headline shown in the Overview / News tabs. Originally a synthetic
/// fixture shape; now also the render model for REAL fetched news (mapped from
/// `TradingFloor.NewsArticle` by `NewsStore`). `url` is the optional tappable
/// article link (fixtures leave it nil).
struct NewsItem: Identifiable, Hashable {
    let id = UUID()
    let source: String
    let headline: String
    let summary: String
    let ageMinutes: Int
    var url: URL? = nil

    var ageLabel: String {
        switch ageMinutes {
        case 0..<60:      return "\(ageMinutes)m ago"
        case 60..<1440:   return "\(ageMinutes / 60)h ago"
        default:          return "\(ageMinutes / 1440)d ago"
        }
    }
}

enum NewsFixtures {

    static let common: [NewsItem] = [
        .init(source: "Investing.com",
              headline: "Markets rise on renewed optimism over U.S.-Iran breakthrough",
              summary: "U.S. futures steady as investors await major tech earnings later this week, with energy sector leading the gains across global markets.",
              ageMinutes: 24 * 60),
        .init(source: "Proactive",
              headline: "Dow Jones and Nasdaq climb as oil eases on reports of Iran sanctions lift",
              summary: "US stocks battled higher on Monday morning, reversing some of the declines from the end of last week, even though investors continued to worry about inflation.",
              ageMinutes: 36 * 60),
        .init(source: "The Telegraph",
              headline: "FTSE 100 Live: European stocks surge on reports of progress in Iran-US negotiations",
              summary: "European indices opened sharply higher, tracking gains in Asia overnight after positive diplomatic signals from both sides.",
              ageMinutes: 48 * 60),
    ]

    static let perSymbol: [String: [NewsItem]] = [
        "AAPL": [
            .init(source: "Bloomberg",
                  headline: "Apple unveils new on-device AI stack at WWDC keynote",
                  summary: "The latest models run inference entirely on-device, eliminating the need for cloud round-trips and addressing privacy concerns raised by enterprise customers.",
                  ageMinutes: 6 * 60),
            .init(source: "Reuters",
                  headline: "Apple expands Vision Pro production lines in Vietnam",
                  summary: "Supply chain partners confirmed expanded capacity to meet anticipated demand following the device's broader regional rollout.",
                  ageMinutes: 18 * 60),
        ],
        "MSFT": [
            .init(source: "CNBC",
                  headline: "Microsoft accelerates Azure data-center build-out for AI workloads",
                  summary: "The company committed to $30B in capex over the next 18 months, citing sustained enterprise demand for managed inference.",
                  ageMinutes: 4 * 60),
        ],
        "NVDA": [
            .init(source: "Investing.com",
                  headline: "Nvidia's Huang expects China to open market for US AI chips",
                  summary: "Nvidia Corp. Chief Executive Officer Jensen Huang said Monday he expects Chinese authorities will allow the import of artificial intelligence accelerators in the next cycle.",
                  ageMinutes: 36 * 60),
            .init(source: "Investing.com",
                  headline: "Dell, Nvidia CEOs discuss shift to personal AI computing at industry event",
                  summary: "Nvidia CEO Jensen Huang and Dell Technologies CEO Michael Dell outlined their vision for distributed AI computing during a Monday roundtable.",
                  ageMinutes: 36 * 60),
        ],
        "GOOGL": [
            .init(source: "WSJ",
                  headline: "Alphabet's TPU v6 lands with 2.4x perf/W improvement",
                  summary: "Google announced general availability of the next-generation TPU, with selected partners reporting double-digit gains on transformer workloads.",
                  ageMinutes: 12 * 60),
        ],
        "TSLA": [
            .init(source: "The Telegraph",
                  headline: "Elon Musk loses legal fight against OpenAI",
                  summary: "A US federal judge dismissed key claims in Musk's lawsuit, allowing OpenAI's structural transition to a capped-profit entity to proceed.",
                  ageMinutes: 48 * 60),
        ],
    ]

    static func items(for symbol: String) -> [NewsItem] {
        (perSymbol[symbol] ?? []) + common
    }
}
