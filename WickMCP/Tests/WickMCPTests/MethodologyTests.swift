import Testing
import Foundation
@testable import WickMCP
import TradingFloor

/// Verifies the `wick.methodology` tool wires correctly to TradingFloor's
/// bundled SkillRegistry and returns playbook content the calling agent
/// can actually act on. These tests don't try to assert against the
/// exact wording in the skills — those evolve — but they do guard the
/// contract: known skill names resolve, unknown ones degrade cleanly,
/// the master playbook lists every skill the registry holds.
@Suite(.serialized)
struct MethodologyTests {

    private func host() -> ToolHost {
        ToolHost(market: StubMarketDataProvider(),
                 eastMoney: EastMoneyMarketDataProvider())
    }

    @Test func methodology_spec_present_in_tools_list() {
        let h = host()
        let names = h.specs.compactMap { $0["name"] as? String }
        #expect(names.contains("wick.methodology"))
    }

    @Test func methodology_with_no_args_returns_master_playbook() async throws {
        let content = try await host().call(name: "wick.methodology",
                                             arguments: [:])
        let text = content[0]["text"] as? String ?? ""
        #expect(text.contains("# Wicker Analysis Playbook"))
        #expect(text.contains("Recommended steps"))
        #expect(text.contains("`wick.snapshot"))      // mentions data tool
        #expect(text.contains("Available methodologies"))
        // The master playbook should reference each bundled skill by name.
        for expected in ["fundamental-analysis", "technical-analysis",
                          "sentiment-analysis", "bull-bear-debate",
                          "full-desk-analysis"] {
            #expect(text.contains("`\(expected)`"),
                    "playbook should list \(expected)")
        }
        // And reinforce that Wick doesn't run the workflow for the agent.
        #expect(text.contains("Wick deliberately does not"))
    }

    @Test func methodology_named_skill_returns_full_body() async throws {
        let content = try await host().call(
            name: "wick.methodology",
            arguments: ["name": "fundamental-analysis"])
        let text = content[0]["text"] as? String ?? ""
        // Frontmatter-derived header.
        #expect(text.contains("# fundamental-analysis"))
        // The skill body must come through — assert on a stable phrase.
        #expect(text.contains("Method"))
        #expect(text.contains("Valuation"))
    }

    @Test func methodology_unknown_name_lists_known_skills() async throws {
        let content = try await host().call(
            name: "wick.methodology",
            arguments: ["name": "this-does-not-exist"])
        let text = content[0]["text"] as? String ?? ""
        #expect(text.contains("Unknown methodology"))
        // Lists the available alternatives so the agent self-corrects.
        #expect(text.contains("fundamental-analysis"))
        #expect(text.contains("technical-analysis"))
    }

    @Test func methodology_empty_name_falls_through_to_playbook() async throws {
        // Whitespace-only / empty `name` should behave like "no name" —
        // surface the master playbook rather than route through the
        // "unknown skill" branch.
        let content = try await host().call(
            name: "wick.methodology",
            arguments: ["name": "   "])
        let text = content[0]["text"] as? String ?? ""
        #expect(text.contains("# Wicker Analysis Playbook"))
    }
}
