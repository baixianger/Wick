import Foundation
import TradingFloor

/// BYO-cookie 雪球 sentiment source, conforming to the package's
/// `SocialSentimentProvider` seam. Pulls discussion lines from the app-scoped
/// `BrowserSessionManager` and maps them into `SocialSentiment` / `SocialPost`.
///
/// Honors the package guardrails (memory: _tradingfloor-data-sources_,
/// _wick-business-model_): the user reads their OWN 雪球 data with their OWN
/// logged-in session on their OWN device.
///   • `requiresUserCredentials = true` — user signs in once in the visible page.
///   • `interactiveOnly = true` — excluded from any fixed/batch/server run by
///     `SocialSentimentTool`'s `interactive` filter.
///
/// CN/HK only (gated via `CNSymbol`): a non-CN symbol yields an empty,
/// clearly-labelled sentiment rather than fabricated chatter.
@available(macOS 26.0, *)
struct XueqiuSentimentProvider: SocialSentimentProvider {
    let sourceName = "雪球 (BYO)"
    let requiresUserCredentials = true
    let interactiveOnly = true

    /// The app-scoped session owner — `@MainActor`, so calls hop to the main
    /// actor (cheap; the heavy work is already async inside the manager).
    private let manager: BrowserSessionManager

    init(manager: BrowserSessionManager) {
        self.manager = manager
    }

    func sentiment(symbol: String, asOf: Date) async throws -> SocialSentiment {
        // Resolve to canonical CN/HK form; non-CN → empty (never fabricate).
        guard let canonical = CNSymbol.parse(symbol) else {
            return SocialSentiment(
                symbol: symbol, asOf: asOf, source: sourceName,
                summary: "雪球 BYO 仅支持 A 股 / 港股标的。",
                posts: [])
        }

        let lines = await manager.discussion(for: canonical)
        let posts = lines.map { SocialPost(source: sourceName, text: $0) }
        let summary = posts.isEmpty
            ? "无可用雪球讨论（未登录 / 会话过期 / 无内容）。"
            : "雪球讨论 \(posts.count) 条（最近热帖，原文未做情绪打分）。"
        return SocialSentiment(
            symbol: canonical, asOf: asOf, source: sourceName,
            summary: summary, posts: posts)
    }
}
