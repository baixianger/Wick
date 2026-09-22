import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Codex subscription inference using the same Responses/SSE wire contract as
/// dsh-codex-adapter's pi-ai provider. Wick owns the surrounding agent loop.
public struct CodexOAuthProvider: LLMProvider {
    public let credentials: CodexCredentialStore
    private let session: URLSession

    public init(credentials: CodexCredentialStore) {
        self.credentials = credentials
        self.session = CodexNetwork.session
    }

    init(credentials: CodexCredentialStore, session: URLSession) {
        self.credentials = credentials; self.session = session
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        var credential = try await credentials.credential()
        for attempt in 0...1 {
            let wire = try Self.makeRequest(request, credential: credential)
            #if canImport(Darwin)
            let (bytes, response) = try await session.bytes(for: wire)
            guard let http = response as? HTTPURLResponse else { throw CodexError.malformedResponse }
            if http.statusCode == 401 && attempt == 0 {
                // Cancel the unused stream before rotating the token.
                bytes.task.cancel()
                credential = try await credentials.credential(rejectedAccessToken: credential.access)
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                bytes.task.cancel()
                throw CodexError.http(http.statusCode)
            }
            var decoder = CodexResponseDecoder()
            defer { bytes.task.cancel() }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                try decoder.receive(line)
                if decoder.completed { break }
            }
            try Task.checkCancellation()
            return try decoder.finish()
            #else
            let (data, status) = try await CodexNetwork.data(wire)
            if status == 401 && attempt == 0 {
                credential = try await credentials.credential(rejectedAccessToken: credential.access)
                continue
            }
            try CodexOAuthClient.check(status)
            var decoder = CodexResponseDecoder()
            for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
                try decoder.receive(line)
            }
            return try decoder.finish()
            #endif
        }
        throw CodexError.invalidCredential
    }

    static func makeRequest(_ input: LLMRequest, credential: CodexCredential) throws -> URLRequest {
        _ = try credential.validated()
        var request = authorizedRequest("https://chatgpt.com/backend-api/codex/responses", credential: credential)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("wick", forHTTPHeaderField: "originator")
        request.setValue("Wick/0.1", forHTTPHeaderField: "User-Agent")
        let messages: [[String: Any]] = input.messages.map { message in
            var content: [[String: Any]] = [[
                "type": message.role == .user ? "input_text" : "output_text", "text": message.content
            ]]
            if message.role == .user {
                content += message.images.map {
                    ["type": "input_image", "image_url": "data:\($0.mimeType);base64,\($0.base64)", "detail": "auto"]
                }
            }
            return ["type": "message", "role": message.role.rawValue, "content": content]
        }
        // The subscription backend requires stream:true and store:false. Do
        // not send Chat Completions' max_tokens/temperature to this endpoint.
        let body: [String: Any] = [
            "model": input.model, "store": false, "stream": true,
            "instructions": input.system.isEmpty ? "You are a helpful assistant." : input.system,
            "input": messages, "text": ["verbosity": "low"], "include": ["reasoning.encrypted_content"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func authorizedRequest(_ url: String, credential: CodexCredential) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        request.setValue("Bearer \(credential.access)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

/// Small bounded SSE decoder. A closed socket or [DONE] without a successful
/// terminal response must never become a partial financial analysis.
struct CodexResponseDecoder {
    private var pending = ""
    private var text = ""
    private var totalBytes = 0
    private(set) var completed = false

    mutating func receive(_ line: String) throws {
        guard !completed else { return }
        totalBytes += line.utf8.count
        guard totalBytes <= 16_777_216 else { throw CodexError.malformedResponse }
        if line.isEmpty { try flush(); return }
        guard line.hasPrefix("data:") else { return }
        let fragment = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        // AsyncBytes.lines implementations can omit empty lines. Every Codex
        // data event is a JSON object; dispatch complete JSON immediately while
        // still accepting events split across multiple data: lines.
        pending += (pending.isEmpty ? "" : "\n") + fragment
        if pending == "[DONE]" || (try? JSONSerialization.jsonObject(with: Data(pending.utf8))) != nil {
            try flush()
        }
    }

    private mutating func flush() throws {
        guard !pending.isEmpty else { return }
        let data = pending
        pending = ""
        if data == "[DONE]" { return }
        guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let type = json["type"] as? String else { throw CodexError.malformedResponse }
        switch type {
        case "response.output_text.delta":
            text += json["delta"] as? String ?? ""
        case "response.completed", "response.done":
            guard let response = json["response"] as? [String: Any],
                  response["status"] as? String == "completed" else { throw CodexError.incompleteResponse }
            let output = response["output"] as? [[String: Any]] ?? []
            let final = output.filter { $0["type"] as? String == "message" }.flatMap {
                $0["content"] as? [[String: Any]] ?? []
            }.compactMap { part -> String? in
                guard part["type"] as? String == "output_text" else { return nil }
                return part["text"] as? String
            }.joined(separator: "\n")
            if !final.isEmpty { text = final }
            completed = true
        case "response.failed", "response.incomplete", "error":
            throw CodexError.incompleteResponse
        default: break // reasoning, item and usage events do not contain final text
        }
    }

    mutating func finish() throws -> String {
        try flush()
        guard completed else { throw CodexError.incompleteResponse }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.empty }
        return text
    }
}

public struct CodexUsage: Sendable {
    public struct Window: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let remainingPercent: Double
        public let seconds: Double
        public let resetsAt: Date?
    }
    public let plan: String?
    public let windows: [Window]
    public let updatedAt: Date

    public static func fetch(credentials: CodexCredentialStore,
                             http: @escaping CodexOAuthClient.HTTP = CodexNetwork.data) async throws -> Self {
        let credential = try await credentials.credential()
        let (data, status) = try await http(CodexOAuthProvider.authorizedRequest(
            "https://chatgpt.com/backend-api/wham/usage", credential: credential))
        // A usage failure does not mutate or delete the login.
        try CodexOAuthClient.check(status)
        return try parse(data)
    }

    static func parse(_ data: Data, now: Date = .now) throws -> Self {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexError.malformedResponse
        }
        var windows: [Window] = []
        func add(_ value: Any?, id: String, name: String) {
            guard let limit = value as? [String: Any] else { return }
            for key in ["primary_window", "secondary_window"] {
                guard let window = limit[key] as? [String: Any],
                      let used = window["used_percent"] as? Double, used.isFinite, (0...100).contains(used),
                      let seconds = window["limit_window_seconds"] as? Double, seconds.isFinite,
                      seconds > 0, seconds <= 315_360_000 else { continue }
                let reset = (window["reset_at"] as? Double).flatMap {
                    $0.isFinite && $0 > 0 && $0 < 253_402_300_800 ? Date(timeIntervalSince1970: $0) : nil
                }
                windows.append(Window(id: "\(id).\(key)", name: name, remainingPercent: 100 - used, seconds: seconds, resetsAt: reset))
            }
        }
        add(json["rate_limit"], id: "codex", name: "Codex")
        for (index, limit) in (json["additional_rate_limits"] as? [[String: Any]] ?? []).enumerated() {
            if let name = limit["limit_name"] as? String ?? limit["metered_feature"] as? String {
                add(limit["rate_limit"], id: "additional.\(index)", name: String(name.prefix(100)))
            }
        }
        return Self(plan: (json["plan_type"] as? String).map { String($0.prefix(80)) }, windows: windows, updatedAt: now)
    }
}
