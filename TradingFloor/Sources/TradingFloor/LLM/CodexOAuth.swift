import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Native implementation of the OAuth contract used by dsh-codex-adapter /
/// pi-ai's openaiCodexProvider. Credentials belong to Wick, never to a CLI.
public enum CodexError: Error, LocalizedError, Sendable, Equatable {
    case signedOut, invalidCredential, loginExpired, invalidCallback, incompleteResponse
    case http(Int), storage, malformedResponse

    public var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to Codex in Settings → Provider."
        case .invalidCredential: "The Codex login is invalid. Sign in again or import a fresh login."
        case .loginExpired: "The Codex login attempt expired. Start a new login."
        case .invalidCallback: "This callback does not match the current login. Paste the full callback URL from this attempt."
        case .incompleteResponse: "Codex stopped before completing its response. Please retry."
        case .http(401), .http(403): "Codex authorization failed. Check your account or sign in again."
        case .http(429): "Codex usage is currently limited. Check your subscription quota and retry later."
        case .http(let status): "Codex request failed (HTTP \(status))."
        case .storage: "Wick could not read or save the Codex login in Keychain."
        case .malformedResponse: "Codex returned an unexpected response."
        }
    }
}

public struct CodexCredential: Codable, Sendable, Equatable {
    public let access: String
    public let refresh: String
    /// Milliseconds since epoch, matching pi-ai's credential format.
    public let expires: Double
    public let accountId: String
    public let email: String?

    public init(access: String, refresh: String, expires: Double, accountId: String, email: String? = nil) {
        self.access = access; self.refresh = refresh; self.expires = expires
        self.accountId = accountId; self.email = email
    }

    public func validated() throws -> Self {
        guard !access.isEmpty, !refresh.isEmpty, !accountId.isEmpty, expires.isFinite,
              !access.contains(where: { $0.isNewline }),
              !accountId.contains(where: { $0.isNewline }) else { throw CodexError.invalidCredential }
        return self
    }

    /// Claims are display/routing metadata only. They never prove authorization.
    static func claims(_ token: String?) -> [String: Any] {
        guard let parts = token?.split(separator: "."), parts.count == 3 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    static func make(access: String, refresh: String, expires: Double, accountId: String? = nil,
                     idToken: String? = nil, email: String? = nil) throws -> Self {
        let accessClaims = claims(access)
        let auth = accessClaims["https://api.openai.com/auth"] as? [String: Any]
        let profile = accessClaims["https://api.openai.com/profile"] as? [String: Any]
        let account = accountId ?? (auth?["chatgpt_account_id"] as? String) ?? ""
        return try Self(access: access, refresh: refresh, expires: expires, accountId: account,
                        email: email ?? (claims(idToken)["email"] as? String)
                            ?? (profile?["email"] as? String) ?? (accessClaims["email"] as? String)).validated()
    }

    /// Explicit import only: no automatic fallback to a file after sign-out.
    /// Accepts Codex CLI auth.json containing OAuth tokens.
    public static func importing(_ data: Data, now: Date = .now) throws -> Self {
        guard data.count <= 1_048_576,
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexError.invalidCredential
        }
        if let tokens = document["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String, let refresh = tokens["refresh_token"] as? String {
            let expiry = (claims(access)["exp"] as? Double).map { $0 * 1000 }
                ?? now.addingTimeInterval(3600).timeIntervalSince1970 * 1000
            return try make(access: access, refresh: refresh, expires: expiry,
                            accountId: tokens["account_id"] as? String, idToken: tokens["id_token"] as? String)
        }
        throw CodexError.invalidCredential
    }
}

/// One owner serializes refresh and persistence for every chat/desk/title call.
/// The epoch prevents a late refresh from resurrecting a logged-out account.
public actor CodexCredentialStore {
    public typealias Read = @Sendable () throws -> CodexCredential?
    public typealias Write = @Sendable (CodexCredential?) throws -> Void
    public typealias Refresh = @Sendable (CodexCredential) async throws -> CodexCredential
    private let read: Read
    private let write: Write
    private let refresh: Refresh
    private var epoch = UUID()
    private var flight: (id: UUID, task: Task<CodexCredential, Error>)?

    public init(read: @escaping Read, write: @escaping Write, refresh: @escaping Refresh) {
        self.read = read; self.write = write; self.refresh = refresh
    }

    public func current() throws -> CodexCredential? { try read()?.validated() }

    public func revision() -> UUID { epoch }

    public func replace(_ credential: CodexCredential?, ifRevision expected: UUID? = nil) throws {
        try Task.checkCancellation()
        if let expected, expected != epoch { throw CancellationError() }
        let validated = try credential?.validated()
        try write(validated)
        epoch = UUID()
        flight?.task.cancel()
        flight = nil
    }

    public func credential(rejectedAccessToken: String? = nil, now: Date = .now) async throws -> CodexCredential {
        try Task.checkCancellation()
        guard let existing = try current() else { throw CodexError.signedOut }
        if existing.expires > now.addingTimeInterval(60).timeIntervalSince1970 * 1000,
           rejectedAccessToken != existing.access { return existing }
        let capturedEpoch = epoch
        if flight == nil {
            let refresh = self.refresh
            let id = UUID()
            flight = (id, Task {
                let renewed = try await refresh(existing).validated()
                guard self.epoch == capturedEpoch else { throw CancellationError() }
                // Persistence is part of the shared task, so ALL waiters see a
                // write failure rather than some returning an unsaved token.
                try self.write(renewed)
                if self.flight?.id == id { self.flight = nil }
                return renewed
            })
        }
        guard let job = flight else { throw CodexError.signedOut }
        do {
            let renewed = try await job.task.value
            guard epoch == capturedEpoch else { throw CancellationError() }
            try Task.checkCancellation()
            return renewed
        } catch {
            if flight?.id == job.id { flight = nil }
            throw error
        }
    }
}

public struct CodexDeviceLogin: Sendable {
    let deviceID: String
    public let userCode: String
    public let interval: TimeInterval
    public let expiresAt: Date
    public var verificationURL: URL { URL(string: "https://auth.openai.com/codex/device")! }
}

public struct CodexBrowserLogin: Sendable {
    public let url: URL
    public let expiresAt: Date
    let verifier: String
    let state: String
}

public struct CodexOAuthClient: Sendable {
    public typealias HTTP = @Sendable (URLRequest) async throws -> (Data, Int)
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let browserRedirect = "http://localhost:1455/auth/callback"
    private let http: HTTP

    public init(http: @escaping HTTP = CodexNetwork.data) { self.http = http }

    public func startDeviceLogin(now: Date = .now) async throws -> CodexDeviceLogin {
        let (data, status) = try await http(Self.jsonRequest(
            "https://auth.openai.com/api/accounts/deviceauth/usercode", body: ["client_id": Self.clientID]))
        try Self.check(status)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = json["device_auth_id"] as? String, !device.isEmpty,
              let code = json["user_code"] as? String, !code.isEmpty,
              let interval = (json["interval"] as? Double) ?? (json["interval"] as? String).flatMap(Double.init),
              interval.isFinite, interval >= 0, interval <= 900 else { throw CodexError.malformedResponse }
        return CodexDeviceLogin(deviceID: device, userCode: code, interval: max(1, interval),
                                expiresAt: now.addingTimeInterval(600))
    }

    public func finishDeviceLogin(_ login: CodexDeviceLogin) async throws -> CodexCredential {
        var delay = login.interval
        while Date.now < login.expiresAt {
            try await Task.sleep(for: .seconds(delay))
            guard Date.now < login.expiresAt else { break }
            let (data, status) = try await http(Self.jsonRequest(
                "https://auth.openai.com/api/accounts/deviceauth/token",
                body: ["device_auth_id": login.deviceID, "user_code": login.userCode]))
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if (200..<300).contains(status) {
                guard let code = json["authorization_code"] as? String,
                      let verifier = json["code_verifier"] as? String else { throw CodexError.malformedResponse }
                return try await exchange(code: code, verifier: verifier,
                                          redirect: "https://auth.openai.com/deviceauth/callback")
            }
            let errorCode = (json["error"] as? String) ?? ((json["error"] as? [String: Any])?["code"] as? String)
            if errorCode == "slow_down" { delay = min(delay + 5, 60); continue }
            if status == 403 || status == 404 || errorCode == "deviceauth_authorization_pending" { continue }
            throw CodexError.http(status)
        }
        throw CodexError.loginExpired
    }

    #if canImport(CryptoKit)
    public func startBrowserLogin(now: Date = .now) -> CodexBrowserLogin {
        func random() -> String { Self.base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) })) }
        let verifier = random(), state = random()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var url = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        url.queryItems = [
            "response_type": "code", "client_id": Self.clientID, "redirect_uri": Self.browserRedirect,
            "scope": "openid profile email offline_access", "code_challenge": challenge,
            "code_challenge_method": "S256", "state": state,
            "id_token_add_organizations": "true", "codex_cli_simplified_flow": "true", "originator": "wick"
        ].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return CodexBrowserLogin(url: url.url!, expiresAt: now.addingTimeInterval(600), verifier: verifier, state: state)
    }
    #endif

    public func finishBrowserLogin(_ login: CodexBrowserLogin, callback: String) async throws -> CodexCredential {
        guard Date.now < login.expiresAt else { throw CodexError.loginExpired }
        guard let url = URLComponents(string: callback.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http", url.host == "localhost", url.port == 1455,
              url.path == "/auth/callback", url.user == nil, url.password == nil else { throw CodexError.invalidCallback }
        let items = url.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == login.state,
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw CodexError.invalidCallback
        }
        return try await exchange(code: code, verifier: login.verifier, redirect: Self.browserRedirect)
    }

    public func refresh(_ credential: CodexCredential) async throws -> CodexCredential {
        let result = try await token(fields: ["grant_type": "refresh_token", "refresh_token": credential.refresh,
                                             "client_id": Self.clientID], previous: credential)
        guard result.accountId == credential.accountId else { throw CodexError.invalidCredential }
        return result
    }

    private func exchange(code: String, verifier: String, redirect: String) async throws -> CodexCredential {
        try await token(fields: ["grant_type": "authorization_code", "client_id": Self.clientID,
                                 "code": code, "code_verifier": verifier, "redirect_uri": redirect])
    }

    private func token(fields: [String: String], previous: CodexCredential? = nil) async throws -> CodexCredential {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
        let (data, status) = try await http(request)
        try Self.check(status)
        struct Tokens: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double; let id_token: String? }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data), tokens.expires_in.isFinite,
              tokens.expires_in > 0, let refresh = tokens.refresh_token ?? previous?.refresh else {
            throw CodexError.malformedResponse
        }
        return try CodexCredential.make(access: tokens.access_token, refresh: refresh,
                                        expires: Date.now.timeIntervalSince1970 * 1000 + tokens.expires_in * 1000,
                                        idToken: tokens.id_token, email: previous?.email)
    }

    static func jsonRequest(_ url: String, body: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
    static func check(_ status: Int) throws { if !(200..<300).contains(status) { throw CodexError.http(status) } }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Never follow a redirect carrying an OAuth grant or authenticated request.
public enum CodexNetwork {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
    public static func data(_ request: URLRequest) async throws -> (Data, Int) {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw CodexError.malformedResponse }
        return (data, response.statusCode)
    }
}
