import Testing
import Foundation
@testable import TradingFloor

#if canImport(Darwin)

@Test func claude_code_flattens_single_user_message() {
    let msgs = [LLMMessage(role: .user, content: "Hello world")]
    #expect(ClaudeCodeProvider.flattenMessages(msgs) == "Hello world")
}

@Test func claude_code_flattens_multi_turn_with_role_labels() {
    let msgs = [
        LLMMessage(role: .user, content: "Hi"),
        LLMMessage(role: .assistant, content: "Hello back"),
        LLMMessage(role: .user, content: "How are you?")
    ]
    let out = ClaudeCodeProvider.flattenMessages(msgs)
    #expect(out.contains("User: Hi"))
    #expect(out.contains("Assistant: Hello back"))
    #expect(out.contains("User: How are you?"))
}

@Test func claude_code_throws_transport_when_binary_missing() async {
    // Resolution falls through with the original path, so Process.run()
    // raises NSPOSIXErrorDomain → LLMError.transport.
    let provider = ClaudeCodeProvider(
        cliPath: "/usr/bin/this-definitely-does-not-exist-\(UUID().uuidString)")
    do {
        _ = try await provider.complete(LLMRequest(
            model: "claude-haiku-4-5-20251001",
            system: "test",
            messages: [LLMMessage(role: .user, content: "hi")],
            maxTokens: 100,
            temperature: 0.5))
        Issue.record("Expected LLMError.transport")
    } catch let LLMError.transport(msg) {
        #expect(msg.contains("Spawn failed"))
    } catch {
        Issue.record("Wrong error type: \(error)")
    }
}

/// Live smoke test. Off by default; flip `CLAUDE_CODE_LIVE=1` to exercise
/// the real subprocess against the user's locally-installed `claude` CLI.
/// Verifies the subscription-mode round trip end-to-end with the Haiku
/// model, since that's what TradingFloor's `quickModel` defaults to.
@Test(.disabled(if: ProcessInfo.processInfo.environment["CLAUDE_CODE_LIVE"] == nil))
func claude_code_live_smoke() async throws {
    let provider = ClaudeCodeProvider(mode: .subscription)
    let reply = try await provider.complete(LLMRequest(
        model: "claude-haiku-4-5-20251001",
        system: "Respond with exactly the single word OK and nothing else.",
        messages: [LLMMessage(role: .user, content: "ping")],
        maxTokens: 20,
        temperature: 0))
    print("[LIVE-CC] subscription reply=\(reply)")
    // The model occasionally re-interprets a one-word prompt rather than
    // echoing literally; assert just that the round-trip produced a
    // non-empty completion, which is what the workflow actually needs.
    #expect(!reply.isEmpty)
}

#endif
