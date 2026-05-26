import Foundation
import TradingFloor

/// Dev/offline fallback used when ANTHROPIC_API_KEY is unset, so the whole
/// pipeline (data fetch → queue → worker → DB save) can be exercised without a
/// real LLM key or token spend. Returns canned, clearly-labelled analysis.
/// NEVER use in production — there's a startup warning when it's active.
struct OfflineLLM: LLMProvider {
    func complete(_ request: LLMRequest) async throws -> String {
        if request.system.contains("Trader") {
            return "HOLD. [offline demo] Balanced setup; awaiting a clearer catalyst."
        }
        if request.system.contains("Risk") {
            return "[offline demo] Decision is reasonable; watch position sizing and macro shifts."
        }
        return "[offline demo] Analysis generated without a live LLM.\nLean: neutral — demo mode."
    }
}
