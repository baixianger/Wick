import Foundation
import Testing
@testable import TradingFloor

private func credential(_ token: String = "old", expires: Double = 0, account: String = "account") -> CodexCredential {
    CodexCredential(access: token, refresh: "refresh-\(token)", expires: expires, accountId: account)
}

private final class CredentialMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CodexCredential?
    private var refreshCount = 0
    init(_ value: CodexCredential?) { self.value = value }
    func read() -> CodexCredential? { lock.withLock { value } }
    func write(_ value: CodexCredential?) { lock.withLock { self.value = value } }
    func countRefresh() { lock.withLock { refreshCount += 1 } }
    var count: Int { lock.withLock { refreshCount } }
}

private actor RefreshGate {
    private var started = false
    private var pending: CheckedContinuation<CodexCredential, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func run() async -> CodexCredential {
        await withCheckedContinuation { continuation in
            pending = continuation
            started = true
            observer?.resume(); observer = nil
        }
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }
    func finish(_ value: CodexCredential) { pending?.resume(returning: value); pending = nil }
}

@Test func codex_refresh_is_shared_and_rotated_credential_is_persisted() async throws {
    let memory = CredentialMemory(credential())
    let renewed = credential("new", expires: Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
    let store = CodexCredentialStore(read: { memory.read() }, write: { memory.write($0) }, refresh: { _ in
        memory.countRefresh()
        try await Task.sleep(for: .milliseconds(20))
        return renewed
    })
    try await withThrowingTaskGroup(of: CodexCredential.self) { group in
        for _ in 0..<20 { group.addTask { try await store.credential() } }
        for try await result in group { #expect(result == renewed) }
    }
    #expect(memory.count == 1)
    #expect(memory.read() == renewed)
    // A concurrent 401 for the OLD token must reuse the already-refreshed token.
    #expect(try await store.credential(rejectedAccessToken: "old") == renewed)
    #expect(memory.count == 1)
}

@Test func codex_logout_cannot_be_undone_by_a_late_refresh() async throws {
    let memory = CredentialMemory(credential()), gate = RefreshGate()
    let store = CodexCredentialStore(read: { memory.read() }, write: { memory.write($0) }, refresh: { _ in await gate.run() })
    let task = Task { try await store.credential() }
    await gate.waitForStart()
    try await store.replace(nil)
    await gate.finish(credential("late"))
    do { _ = try await task.value; Issue.record("Late refresh should fail") }
    catch is CancellationError { }
    #expect(memory.read() == nil)
    await #expect(throws: CodexError.signedOut) { try await store.credential() }
}

@Test func codex_account_replacement_wins_over_old_refresh() async throws {
    let memory = CredentialMemory(credential()), gate = RefreshGate()
    let store = CodexCredentialStore(read: { memory.read() }, write: { memory.write($0) }, refresh: { _ in await gate.run() })
    let task = Task { try await store.credential() }
    await gate.waitForStart()
    let other = credential("other", account: "different-account")
    try await store.replace(other)
    await gate.finish(credential("late"))
    do { _ = try await task.value; Issue.record("Old account should not finish refresh") }
    catch is CancellationError { }
    #expect(memory.read() == other)
}

@Test func codex_stale_login_commit_does_not_restore_signed_out_account() async throws {
    let memory = CredentialMemory(nil)
    let store = CodexCredentialStore(read: { memory.read() }, write: { memory.write($0) }, refresh: { $0 })
    let revision = await store.revision()
    try await store.replace(nil)
    await #expect(throws: CancellationError.self) {
        try await store.replace(credential(), ifRevision: revision)
    }
    #expect(memory.read() == nil)
}

@Test func codex_failed_persistence_never_reports_a_successful_refresh() async throws {
    let old = credential()
    let store = CodexCredentialStore(read: { old }, write: { _ in throw CodexError.storage }, refresh: { _ in credential("new") })
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
            group.addTask { await #expect(throws: CodexError.storage) { try await store.credential() } }
        }
    }
}

#if canImport(Darwin)
private final class CodexHTTPStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let rejected = request.value(forHTTPHeaderField: "Authorization") == "Bearer old"
        let response = HTTPURLResponse(url: request.url!, statusCode: rejected ? 401 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !rejected {
            let body = #"data: {"type":"response.output_text.delta","delta":"OK"}"# + "\n\n"
                + #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n"
            client?.urlProtocol(self, didLoad: Data(body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@Test func codex_provider_retries_401_once_with_refreshed_token_and_reads_sse() async throws {
    let future = Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000
    let memory = CredentialMemory(credential(expires: future))
    let store = CodexCredentialStore(read: { memory.read() }, write: { memory.write($0) }, refresh: { _ in
        memory.countRefresh()
        return credential("new", expires: future)
    })
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CodexHTTPStub.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let provider = CodexOAuthProvider(credentials: store, session: session)
    let output = try await provider.complete(LLMRequest(model: "test", system: "test",
                                                       messages: [.init(role: .user, content: "test")],
                                                       maxTokens: 20, temperature: 0))
    #expect(output == "OK")
    #expect(memory.count == 1)
}
#endif

@Test func codex_import_accepts_cli_oauth_but_rejects_adapter_and_api_keys() throws {
    let adapter = Data(#"{"version":1,"credential":{"type":"oauth","access":"access","refresh":"refresh","expires":12345,"accountId":"acct","email":"user@example.test"}}"#.utf8)
    #expect(throws: CodexError.invalidCredential) { try CodexCredential.importing(adapter) }
    let payload = CodexOAuthClient.base64URL(Data(#"{"exp":123,"https://api.openai.com/auth":{"chatgpt_account_id":"acct"}}"#.utf8))
    let access = "header.\(payload).signature"
    let cli = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": access, "refresh_token": "refresh"]])
    let cliCredential = try CodexCredential.importing(cli)
    #expect(cliCredential.expires == 123000)
    #expect(cliCredential.accountId == "acct")
    #expect(throws: CodexError.invalidCredential) { try CodexCredential.importing(Data(#"{"OPENAI_API_KEY":"not-oauth"}"#.utf8)) }
    #expect(throws: CodexError.invalidCredential) { try CodexCredential.importing(Data(#"{"credential":{"type":"oauth","access":"secret"}}"#.utf8)) }
}

#if canImport(CryptoKit)
@Test func codex_browser_flow_validates_state_and_exchanges_pkce() async throws {
    let payload = CodexOAuthClient.base64URL(Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct"}}"#.utf8))
    let oauth = CodexOAuthClient(http: { request in
        #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("code_verifier="))
        #expect(body.contains("grant_type=authorization_code"))
        let response = try JSONSerialization.data(withJSONObject: ["access_token": "header.\(payload).signature", "refresh_token": "refresh", "expires_in": 3600])
        return (response, 200)
    })
    let login = oauth.startBrowserLogin()
    let query = URLComponents(url: login.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.contains { $0.name == "code_challenge_method" && $0.value == "S256" })
    await #expect(throws: CodexError.invalidCallback) {
        try await oauth.finishBrowserLogin(login, callback: "http://localhost:1455/auth/callback?code=code&state=wrong")
    }
    await #expect(throws: CodexError.invalidCallback) {
        try await oauth.finishBrowserLogin(login, callback: "https://evil.test/auth/callback?code=code&state=\(login.state)")
    }
    #expect(try await oauth.finishBrowserLogin(login, callback: "http://localhost:1455/auth/callback?code=code&state=\(login.state)").accountId == "acct")
    let expired = oauth.startBrowserLogin(now: .distantPast)
    await #expect(throws: CodexError.loginExpired) { try await oauth.finishBrowserLogin(expired, callback: "code") }
}
#endif

@Test func codex_device_response_handles_string_intervals_and_cancellation() async throws {
    let client = CodexOAuthClient(http: { _ in (Data(#"{"device_auth_id":"device","user_code":"ABC-123","interval":"5"}"#.utf8), 200) })
    let login = try await client.startDeviceLogin()
    #expect(login.userCode == "ABC-123")
    #expect(login.interval == 5)
    let task = Task { try await client.finishDeviceLogin(login) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func codex_requests_preserve_history_and_images_without_api_key_options() throws {
    let input = LLMRequest(model: "chosen-model", system: "Wick analyst", messages: [
        LLMMessage(role: .user, content: "look", images: [LLMImage(mimeType: "image/png", base64: "YWJj")]),
        LLMMessage(role: .assistant, content: "previous answer"), LLMMessage(role: .user, content: "continue")
    ], maxTokens: 1500, temperature: 0.7)
    let request = try CodexOAuthProvider.makeRequest(input, credential: credential())
    #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
    #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "account")
    let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    #expect(body["store"] as? Bool == false)
    #expect(body["stream"] as? Bool == true)
    #expect(body["temperature"] == nil)
    #expect(body["max_tokens"] == nil)
    let messages = try #require(body["input"] as? [[String: Any]])
    #expect(messages.count == 3)
    let content = try #require(messages[0]["content"] as? [[String: Any]])
    #expect(content[1]["image_url"] as? String == "data:image/png;base64,YWJj")
}

@Test func codex_sse_requires_completion_and_uses_final_text_once() throws {
    var decoder = CodexResponseDecoder()
    try decoder.receive("event: response.output_text.delta")
    try decoder.receive(#"data: {"type":"response.output_text.delta","delta":"partial"}"#)
    try decoder.receive(#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"final 中文"}]}]}}"#)
    #expect(try decoder.finish() == "final 中文")
    var truncated = CodexResponseDecoder()
    try truncated.receive(#"data: {"type":"response.output_text.delta","delta":"partial"}"#)
    try truncated.receive("data: [DONE]")
    #expect(throws: CodexError.incompleteResponse) { try truncated.finish() }
    var failed = CodexResponseDecoder()
    #expect(throws: CodexError.incompleteResponse) {
        try failed.receive(#"data: {"type":"response.failed","response":{"status":"failed","error":{"message":"secret"}}}"#)
    }
}

@Test func codex_usage_preserves_unknown_and_does_not_clear_credentials_on_failure() async throws {
    let usage = try CodexUsage.parse(Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":12345},"secondary_window":null}}"#.utf8))
    #expect(usage.windows.count == 1)
    #expect(usage.windows[0].remainingPercent == 75)
    #expect(try CodexUsage.parse(Data(#"{"rate_limit":{"primary_window":{"used_percent":105,"limit_window_seconds":18000}}}"#.utf8)).windows.isEmpty)
    let valid = credential(expires: Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
    let memory = CredentialMemory(valid)
    let store = CodexCredentialStore(read: { memory.read() }, write: { memory.write($0) }, refresh: { $0 })
    await #expect(throws: CodexError.http(503)) {
        try await CodexUsage.fetch(credentials: store, http: { _ in (Data("secret".utf8), 503) })
    }
    #expect(memory.read() == valid)
}
