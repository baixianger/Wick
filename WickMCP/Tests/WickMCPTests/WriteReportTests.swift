import Testing
import Foundation
@testable import WickMCP
import TradingFloor

/// Verifies the `wick.write_report` tool: argument validation, mapping
/// to a `Report`, persistence into `SharedStore` (the same store Wick.app's
/// `ReportHistoryStore` reads from), and provenance stamping.
///
/// Serialized because the tests share the on-disk reports directory and
/// they read each other's files otherwise.
@Suite(.serialized)
struct WriteReportTests {

    private func host() -> ToolHost {
        ToolHost(market: StubMarketDataProvider(),
                 eastMoney: EastMoneyMarketDataProvider())
    }

    /// Wipe the reports directory so test n doesn't see test n-1's output.
    private func wipeReportsDirectory() {
        let fm = FileManager.default
        let dir = SharedStore.reportsDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.pathExtension == "json" {
            try? fm.removeItem(at: entry)
        }
    }

    @Test func writereport_spec_in_tools_list() {
        let names = host().specs.compactMap { $0["name"] as? String }
        #expect(names.contains("wick.write_report"))
    }

    @Test func writereport_requires_ticker() async {
        let h = host()
        do {
            _ = try await h.call(name: "wick.write_report",
                                  arguments: ["rating": "BUY",
                                              "summary": "ok"])
            Issue.record("Expected invalidArgument for missing ticker")
        } catch MCPToolError.invalidArgument {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test func writereport_requires_summary() async {
        let h = host()
        do {
            _ = try await h.call(name: "wick.write_report",
                                  arguments: ["ticker": "NVDA",
                                              "rating": "BUY"])
            Issue.record("Expected invalidArgument for missing summary")
        } catch MCPToolError.invalidArgument {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test func writereport_rejects_unknown_rating() async {
        let h = host()
        do {
            _ = try await h.call(name: "wick.write_report",
                                  arguments: ["ticker": "NVDA",
                                              "rating": "MAYBE",
                                              "summary": "unsure"])
            Issue.record("Expected invalidArgument for bad rating")
        } catch MCPToolError.invalidArgument {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test func writereport_accepts_underscored_strong_ratings() async throws {
        wipeReportsDirectory()
        defer { wipeReportsDirectory() }

        let h = host()
        let content = try await h.call(
            name: "wick.write_report",
            arguments: [
                "ticker": "600519.SS",
                "rating": "STRONG_BUY",
                "summary": "Premium positioning, fair value above current price."
            ])
        let text = content[0]["text"] as? String ?? ""
        #expect(text.contains("Strong Buy"))

        // Re-read the persisted report.
        let stored = SharedStore.reports()
        #expect(stored.contains { $0.ticker == "600519.SS" && $0.rating == .strongBuy })
    }

    @Test func writereport_persists_full_report_to_sharedstore() async throws {
        wipeReportsDirectory()
        defer { wipeReportsDirectory() }

        let h = host()
        let beforeCount = SharedStore.reports().count
        _ = try await h.call(
            name: "wick.write_report",
            arguments: [
                "ticker": "AAPL",
                "rating": "BUY",
                "summary": "Services revenue mix continues to expand margins.",
                "transcript": [
                    ["role": "Fundamental Analyst", "content": "FY revenue +8% YoY, services 26% of mix."],
                    ["role": "Technical Analyst",   "content": "RSI 58, MACD bullish crossover 4 sessions ago."],
                    ["role": "Bull Researcher",     "content": "Buybacks at scale + iPhone 17 cycle."],
                    ["role": "Bear Researcher",     "content": "China demand softening; FX headwind."],
                    ["role": "Trader",              "content": "Initiate at 6% target weight."],
                    ["role": "Risk Manager",        "content": "Watch China shipments + USD trajectory."]
                ],
                "position_percent": 6.0,
                "client": "claude-code"
            ])

        let stored = SharedStore.reports()
        #expect(stored.count == beforeCount + 1)
        guard let r = stored.first(where: { $0.ticker == "AAPL" }) else {
            Issue.record("Report not persisted"); return
        }
        #expect(r.rating == .buy)
        #expect(r.summary.contains("Services"))
        #expect(r.transcript.count == 6)
        #expect(r.transcript.first?.role == "Fundamental Analyst")
        #expect(r.position?.targetWeight == 0.06)
        #expect(r.source == "mcp:claude-code")
    }

    @Test func writereport_source_falls_back_when_client_omitted() async throws {
        wipeReportsDirectory()
        defer { wipeReportsDirectory() }

        let h = host()
        _ = try await h.call(
            name: "wick.write_report",
            arguments: [
                "ticker": "TSLA",
                "rating": "HOLD",
                "summary": "Range-bound."
            ])
        let stored = SharedStore.reports().first { $0.ticker == "TSLA" }
        #expect(stored?.source == "mcp:external")
    }

    @Test func writereport_position_percent_is_optional() async throws {
        wipeReportsDirectory()
        defer { wipeReportsDirectory() }

        let h = host()
        _ = try await h.call(
            name: "wick.write_report",
            arguments: [
                "ticker": "GOOG",
                "rating": "HOLD",
                "summary": "Awaiting Q earnings."
            ])
        let stored = SharedStore.reports().first { $0.ticker == "GOOG" }
        #expect(stored?.position == nil)
    }

    @Test func writereport_transcript_with_bad_rows_drops_them_silently() async throws {
        wipeReportsDirectory()
        defer { wipeReportsDirectory() }

        let h = host()
        _ = try await h.call(
            name: "wick.write_report",
            arguments: [
                "ticker": "MSFT",
                "rating": "BUY",
                "summary": "Azure + Copilot.",
                "transcript": [
                    ["role": "Fundamental", "content": "Cloud growth +30%."],
                    ["role": "", "content": "missing role"],                  // dropped
                    ["role": "Trader"],                                       // missing content, dropped
                    ["wrong": "shape"],                                       // dropped
                    ["role": "Risk Manager", "content": "AI capex risk."]
                ]
            ])
        let stored = SharedStore.reports().first { $0.ticker == "MSFT" }
        #expect(stored?.transcript.count == 2)
        #expect(stored?.transcript.first?.role == "Fundamental")
        #expect(stored?.transcript.last?.role == "Risk Manager")
    }
}
