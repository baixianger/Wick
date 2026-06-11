import Testing
import Foundation
@testable import TradingFloor

/// Coverage for the registry's `unregister` path that the host uses to retract
/// Wicker's opt-in `web.*` browser tools when the feature is toggled off.

private struct FakeTool: AgentTool {
    let name: String
    var spec: ToolSpec { ToolSpec(name: name, description: "fake", parametersJSONSchema: "{}") }
    func call(arguments: Data) async throws -> String { "ok" }
}

@Test func registry_unregister_removes_named_tool() async {
    let reg = ToolRegistry()
    await reg.registerAll([FakeTool(name: "web.navigate"), FakeTool(name: "get_market_data")])
    #expect(await reg.tool(named: "web.navigate") != nil)

    await reg.unregister(name: "web.navigate")
    #expect(await reg.tool(named: "web.navigate") == nil)
    // Unrelated tools are untouched.
    #expect(await reg.tool(named: "get_market_data") != nil)
}

@Test func registry_unregister_unknown_is_noop() async {
    let reg = ToolRegistry()
    await reg.register(FakeTool(name: "keep"))
    await reg.unregister(name: "does.not.exist")
    #expect(await reg.tool(named: "keep") != nil)
}

@Test func registry_unregisterAll_retracts_the_web_family() async {
    let reg = ToolRegistry()
    let names = ["web.navigate", "web.read", "web.snapshot", "web.click",
                 "web.type", "web.eval", "web.fetchJSON"]
    await reg.registerAll(names.map { FakeTool(name: $0) } + [FakeTool(name: "get_market_data")])
    await reg.unregisterAll(names: names)
    for n in names { #expect(await reg.tool(named: n) == nil) }
    #expect(await reg.tool(named: "get_market_data") != nil)
}
