import Foundation
import TradingFloor

/// Bare-bones MCP (Model Context Protocol) server over stdio.
///
/// Reads newline-delimited JSON-RPC 2.0 messages from stdin, dispatches
/// `initialize` / `tools/list` / `tools/call` / `ping` / `notifications/*`,
/// writes JSON-RPC responses to stdout, and routes diagnostics to stderr
/// (stdout is reserved for the protocol — any stray print there corrupts
/// the stream and the client disconnects).
///
/// The implementation is intentionally untyped on the inbound side
/// (`[String: Any]`) because each method shapes `params` differently and
/// Codable-as-a-sum-type is more boilerplate than this protocol deserves
/// at Step-1 scope. Outbound responses go through `JSONSerialization` for
/// the same reason — round-tripping through Codable types we'd only use
/// once buys nothing.
///
/// References:
/// - MCP base spec: https://modelcontextprotocol.io/specification
/// - JSON-RPC 2.0:   https://www.jsonrpc.org/specification
final class MCPServer {
    private let tools: ToolHost

    init(tools: ToolHost) {
        self.tools = tools
    }

    /// Drive the stdio loop until the client closes stdin. Each line is
    /// processed sequentially: an MCP client never pipelines requests
    /// without an intervening response on the same channel.
    func run() async {
        let lines = FileHandle.standardInput.bytes.lines
        do {
            for try await line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                await dispatch(line: trimmed)
            }
        } catch {
            // EOF or pipe break — natural shutdown. Log and return.
            log("stdin read terminated: \(error)")
        }
    }

    // MARK: - Dispatch

    private func dispatch(line: String) async {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            // We received bytes we can't parse. Surface the parse error
            // back; if there's no `id` to bind it to, log only.
            log("parse error: \(line.prefix(200))")
            writeError(id: nil, code: -32700, message: "Parse error")
            return
        }

        let method = obj["method"] as? String ?? ""
        let id = obj["id"]                                       // Int / String / nil
        let params = (obj["params"] as? [String: Any]) ?? [:]

        switch method {
        case "initialize":
            writeResult(id: id, result: handleInitialize(params: params))

        case "notifications/initialized", "notifications/cancelled":
            // Notifications carry no id and expect no reply — just absorb.
            break

        case "ping":
            writeResult(id: id, result: [:])

        case "tools/list":
            writeResult(id: id, result: handleToolsList())

        case "tools/call":
            let result = await handleToolsCall(params: params)
            switch result {
            case .ok(let payload):
                writeResult(id: id, result: payload)
            case .protocolError(let code, let message):
                writeError(id: id, code: code, message: message)
            }

        case "":
            // Missing method — JSON-RPC requires it.
            writeError(id: id, code: -32600, message: "Invalid Request: missing method")

        default:
            writeError(id: id, code: -32601,
                       message: "Method not found: \(method)")
        }
    }

    // MARK: - initialize

    private func handleInitialize(params: [String: Any]) -> [String: Any] {
        // The client tells us its protocol version; we MUST echo back the
        // version we support. The spec allows us to choose ours; clients
        // negotiate down if they understand both.
        // We're targeting 2024-11-05 — most widely deployed stable.
        let serverInfo: [String: Any] = [
            "name": "wick",
            "version": "0.1.0"
        ]
        let capabilities: [String: Any] = [
            "tools": ["listChanged": false]
        ]
        return [
            "protocolVersion": "2024-11-05",
            "capabilities": capabilities,
            "serverInfo": serverInfo
        ]
    }

    // MARK: - tools/list

    private func handleToolsList() -> [String: Any] {
        ["tools": tools.specs]
    }

    // MARK: - tools/call

    enum CallOutcome {
        case ok([String: Any])
        case protocolError(code: Int, message: String)
    }

    private func handleToolsCall(params: [String: Any]) async -> CallOutcome {
        guard let name = params["name"] as? String else {
            return .protocolError(code: -32602,
                                   message: "Missing required parameter: name")
        }
        let arguments = (params["arguments"] as? [String: Any]) ?? [:]

        do {
            let content = try await tools.call(name: name, arguments: arguments)
            return .ok([
                "content": content,
                "isError": false
            ])
        } catch let MCPToolError.unknown(name) {
            return .protocolError(code: -32602,
                                   message: "Unknown tool: \(name)")
        } catch let MCPToolError.invalidArgument(reason) {
            return .protocolError(code: -32602,
                                   message: "Invalid arguments: \(reason)")
        } catch {
            // Tool-runtime failures (network, parsing, etc.) are reported
            // as an MCP "error result" inside `content` rather than a
            // JSON-RPC protocol error — that way the calling LLM sees the
            // message in the tool's transcript instead of the call vanishing.
            return .ok([
                "content": [["type": "text", "text": "Tool error: \(error)"]],
                "isError": true
            ])
        }
    }

    // MARK: - Write

    private func writeResult(id: Any?, result: [String: Any]) {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id { envelope["id"] = id }
        emit(envelope)
    }

    private func writeError(id: Any?, code: Int, message: String) {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ]
        ]
        envelope["id"] = id ?? NSNull()
        emit(envelope)
    }

    private func emit(_ object: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object,
                                                   options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))   // '\n'
        } catch {
            log("emit serialization error: \(error)")
        }
    }
}

/// Stderr is the only safe place to log from an MCP server — stdout
/// belongs to the protocol stream.
func log(_ message: String) {
    let line = "[wick-mcp] \(message)\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

// MARK: - Errors

enum MCPToolError: Error {
    /// Caller asked for a tool we don't expose.
    case unknown(String)
    /// Required argument missing or had wrong type.
    case invalidArgument(String)
}
