import Testing
import Foundation
@testable import TradingFloor

/// Unit coverage for the token-/length-bounding helper that every `web.*` tool
/// (and any future large-output tool) runs its result through before handing it
/// back to the model. WebKit-free, so it lives in the package test target.

@Test func bound_passes_short_text_through_unchanged() {
    let s = "short result"
    #expect(ToolResultBounding.bound(s, limit: 100) == s)
}

@Test func bound_passes_text_at_exact_limit_unchanged() {
    let s = String(repeating: "x", count: 50)
    #expect(ToolResultBounding.bound(s, limit: 50) == s)
}

@Test func bound_truncates_and_marks_overflow() {
    let s = String(repeating: "x", count: 200)
    let out = ToolResultBounding.bound(s, limit: 50)
    #expect(out.hasPrefix(String(repeating: "x", count: 50)))
    #expect(out.contains("[truncated 150 chars]"))
    // The marker must report the exact number dropped.
    #expect(out.contains("150"))
}

@Test func bound_keeps_grapheme_clusters_intact() {
    // Emoji + combining marks: prefix(_:) is grapheme-safe, so cutting must
    // never split a Character (no malformed scalars in the output).
    let s = String(repeating: "👨‍👩‍👧‍👦", count: 20)   // 20 family emoji (1 grapheme each)
    let out = ToolResultBounding.bound(s, limit: 5)
    // First 5 graphemes kept, then the marker — still valid Swift String.
    #expect(out.hasPrefix(String(repeating: "👨‍👩‍👧‍👦", count: 5)))
    #expect(out.contains("[truncated 15 chars]"))
}

@Test func bound_zero_limit_returns_empty() {
    #expect(ToolResultBounding.bound("anything", limit: 0).isEmpty)
}

@Test func bound_default_limit_is_generous_but_finite() {
    let huge = String(repeating: "a", count: ToolResultBounding.defaultLimit + 500)
    let out = ToolResultBounding.bound(huge)
    #expect(out.count < huge.count)
    #expect(out.contains("[truncated 500 chars]"))
}
