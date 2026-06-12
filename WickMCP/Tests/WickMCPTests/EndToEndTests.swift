import Testing
import Foundation
@testable import WickMCP
import TradingFloor

/// End-to-end integration: spawn the actual built `WickMCP` binary as a
/// subprocess (the same one Claude Code would spawn) and pipe JSON-RPC
/// to it over stdio. Verifies the protocol handshake, `tools/list`
/// shape, and the full read path through `SharedStore` → `ToolHost`
/// → MCP `content` block.
///
/// We seed `SharedStore` from the test process first — that simulates
/// what `Wick.app`'s `HoldingsStore` writes when the user clicks
/// "Save" in the Holdings editor. In an unsigned dev build, both the
/// test process and the spawned helper resolve `SharedStore.defaults`
/// to `.standard`, so they share the same on-disk plist. In a signed
/// MAS build, both processes get the same App-Group container — same
/// effect, different physical path.
///
/// The build product path is resolved relative to `#filePath`, so the
/// test stays robust against DerivedData being cleaned between runs.
@Suite(.serialized)
struct WickMCPEndToEndTests {

    /// Path to the just-built `WickMCP` binary.
    static func binaryPath() throws -> String {
        // `#filePath` → .../WickMCP/Tests/WickMCPTests/EndToEndTests.swift
        // ...../WickMCP/.build/<triple>/debug/WickMCP
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here
            .deletingLastPathComponent()        // WickMCPTests
            .deletingLastPathComponent()        // Tests
            .deletingLastPathComponent()        // WickMCP
        let build = packageRoot
            .appendingPathComponent(".build", isDirectory: true)
        // Pick whichever triple SPM emitted (usually arm64-apple-macosx).
        let fm = FileManager.default
        let triples = (try? fm.contentsOfDirectory(atPath: build.path)) ?? []
        for triple in triples {
            let candidate = build
                .appendingPathComponent(triple)
                .appendingPathComponent("debug")
                .appendingPathComponent("WickMCP")
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        throw IntegrationError.binaryNotFound(build.path)
    }

    enum IntegrationError: Error {
        case binaryNotFound(String)
        case ipcTimeout
    }

    /// Spawn the helper, write `requests` (one JSON-RPC envelope per
    /// line), wait for it to drain, and parse stdout into JSON
    /// dictionaries. Used by every test below.
    static func roundTrip(_ requests: [String]) throws -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try binaryPath())
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        for req in requests {
            stdin.fileHandleForWriting.write(req.data(using: .utf8)!)
            stdin.fileHandleForWriting.write(Data([0x0a]))   // newline
        }
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
    }

    private func wipe() {
        UserDefaults.standard.removeObject(forKey: SharedStore.Keys.holdings)
        UserDefaults.standard.removeObject(forKey: SharedStore.Keys.watchlist)
        SharedStore.defaults.removeObject(forKey: SharedStore.Keys.holdings)
        SharedStore.defaults.removeObject(forKey: SharedStore.Keys.watchlist)
    }

    // MARK: - Protocol handshake

    @Test func e2e_initialize_returns_correct_protocol_version() throws {
        let requests = [
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}
            """
        ]
        let responses = try Self.roundTrip(requests)
        guard let first = responses.first,
              let result = first["result"] as? [String: Any] else {
            Issue.record("No initialize response")
            return
        }
        #expect(result["protocolVersion"] as? String == "2024-11-05")
        let serverInfo = result["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "wick")
    }

    @Test func e2e_tools_list_exposes_all_tools() throws {
        let requests = [
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}
            """,
            """
            {"jsonrpc":"2.0","method":"notifications/initialized"}
            """,
            """
            {"jsonrpc":"2.0","id":2,"method":"tools/list"}
            """
        ]
        let responses = try Self.roundTrip(requests)
        let toolsResponse = responses.first { ($0["id"] as? Int) == 2 }
        let result = toolsResponse?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]] ?? []
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names.sorted() == [
            "wick.candles",
            "wick.holdings",
            "wick.methodology",
            "wick.portfolio",
            "wick.snapshot",
            "wick.watchlist",
            "wick.web_navigate",
            "wick.web_read",
            "wick.web_snapshot",
            "wick.write_report",
            "wick.x_discussion",
            "wick.xueqiu_discussion"
        ])
    }

    @Test func e2e_unknown_method_returns_method_not_found() throws {
        let requests = [
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}
            """,
            """
            {"jsonrpc":"2.0","id":99,"method":"does/not/exist"}
            """
        ]
        let responses = try Self.roundTrip(requests)
        let unknown = responses.first { ($0["id"] as? Int) == 99 }
        let error = unknown?["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32601)   // Method not found
    }

    // MARK: - GUI-writes-then-helper-reads (the actual user flow)

    @Test func e2e_holdings_seeded_by_gui_layer_visible_to_helper() throws {
        wipe()
        defer { wipe() }

        // What `HoldingsStore.save()` would write when the user adds a
        // transaction in the Wick GUI. The helper, running in a
        // separate process, reads it back through `SharedStore`.
        let row = SharedHolding(
            symbol: "600519.SS", name: "贵州茅台", side: "buy",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            quantity: 50, price: 1300, currency: "CNY")
        SharedStore.saveHoldings([row])
        UserDefaults.standard.synchronize()

        let requests = [
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}
            """,
            """
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"wick.holdings","arguments":{}}}
            """
        ]
        let responses = try Self.roundTrip(requests)
        let call = responses.first { ($0["id"] as? Int) == 2 }
        let result = call?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]] ?? []
        let markdown = content.first?["text"] as? String ?? ""
        #expect(markdown.contains("600519.SS"))
        #expect(markdown.contains("贵州茅台"))
        #expect(markdown.contains("50"))    // quantity
    }

    @Test func e2e_external_agent_writes_report_visible_to_gui_store() throws {
        // Closes the loop: external MCP client writes a report via
        // wick.write_report → file lands in the shared App-Group
        // container → Wick.app's ReportHistoryStore (read from
        // SharedStore.reports()) sees it next time it refreshes.
        wipe()
        defer { wipe() }

        // Drop any pre-existing report file for our test ticker (use a
        // sentinel that won't collide with anything real).
        let dir = SharedStore.reportsDirectory
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) {
            for e in entries where e.lastPathComponent.hasPrefix("E2E-TEST-") {
                try? FileManager.default.removeItem(at: e)
            }
        }

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"wick.write_report","arguments":{"ticker":"E2E-TEST-1","rating":"BUY","summary":"Closing the loop from MCP back to GUI.","transcript":[{"role":"Fundamental Analyst","content":"Revenue solid."},{"role":"Trader","content":"BUY at 5%."}],"position_percent":5,"client":"e2e-test"}}}"#
        ]
        let responses = try Self.roundTrip(requests)
        let call = responses.first { ($0["id"] as? Int) == 2 }
        let result = call?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]] ?? []
        let ack = content.first?["text"] as? String ?? ""
        #expect(ack.contains("Saved report"))
        #expect(ack.contains("E2E-TEST-1"))

        // Now look at the persisted report from this (the test) process —
        // simulating what Wick.app's ReportHistoryStore would see.
        let stored = SharedStore.reports().first { $0.ticker == "E2E-TEST-1" }
        #expect(stored != nil)
        #expect(stored?.rating == .buy)
        #expect(stored?.source == "mcp:e2e-test")
        #expect(stored?.transcript.count == 2)
        #expect(stored?.position?.targetWeight == 0.05)

        // Cleanup our sentinel file from the shared directory.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) {
            for e in entries where e.lastPathComponent.hasPrefix("E2E-TEST-") {
                try? FileManager.default.removeItem(at: e)
            }
        }
    }

    @Test func e2e_watchlist_seeded_by_gui_layer_visible_to_helper() throws {
        wipe()
        defer { wipe() }

        SharedStore.saveWatchlistGroups([
            SharedWatchlistGroup(name: "AI", symbols: ["NVDA", "GOOGL"])
        ])
        UserDefaults.standard.synchronize()

        let requests = [
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}
            """,
            """
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"wick.watchlist","arguments":{}}}
            """
        ]
        let responses = try Self.roundTrip(requests)
        let call = responses.first { ($0["id"] as? Int) == 2 }
        let result = call?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]] ?? []
        let markdown = content.first?["text"] as? String ?? ""
        #expect(markdown.contains("**AI**"))
        #expect(markdown.contains("NVDA"))
        #expect(markdown.contains("GOOGL"))
    }
}
