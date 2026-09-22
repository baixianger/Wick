import Foundation
import Observation
import Security
import TradingFloor

/// Secret persistence has exactly one owner. No fallback to ~/.codex files:
/// imports copy once, and signing out cannot revive an old file login.
enum CodexKeychain {
    static let credentials = CodexCredentialStore(
        read: { try load() }, write: { try save($0) },
        refresh: { try await CodexOAuthClient().refresh($0) })

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Wick",
         kSecAttrAccount as String: "me.impai.wick.codex-oauth",
         kSecUseDataProtectionKeychain as String: true]
    }

    private static func load() throws -> CodexCredential? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CodexError.storage }
        guard let credential = try? JSONDecoder().decode(CodexCredential.self, from: data) else {
            throw CodexError.invalidCredential
        }
        return try credential.validated()
    }

    private static func save(_ credential: CodexCredential?) throws {
        guard let credential else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CodexError.storage }
            return
        }
        let data = try JSONEncoder().encode(credential)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CodexError.storage }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw CodexError.storage }
    }
}

@MainActor @Observable
final class CodexAccount {
    private(set) var isSignedIn = false
    private(set) var accountLabel: String?
    private(set) var expiresAt: Date?
    private(set) var deviceLogin: CodexDeviceLogin?
    private(set) var browserLogin: CodexBrowserLogin?
    private(set) var isLoggingIn = false
    private(set) var error: String?
    private(set) var usage: CodexUsage?
    private(set) var usageError: String?
    private(set) var loadingUsage = false
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var loginID = UUID()
    @ObservationIgnored private var accountRevision = UUID()
    @ObservationIgnored private let oauth = CodexOAuthClient()

    var provider: CodexOAuthProvider { CodexOAuthProvider(credentials: CodexKeychain.credentials) }

    init() { Task { await refreshStatus() } }

    func refreshStatus() async {
        let revision = accountRevision
        do {
            let credential = try await CodexKeychain.credentials.current()
            guard revision == accountRevision else { return }
            show(credential)
        } catch {
            guard revision == accountRevision else { return }
            self.error = error.localizedDescription
        }
    }

    func signInWithDeviceCode() {
        cancelLogin()
        error = nil
        isLoggingIn = true
        let id = loginID
        loginTask = Task {
            do {
                let device = try await oauth.startDeviceLogin()
                try Task.checkCancellation()
                guard id == loginID else { return }
                deviceLogin = device
                let credential = try await oauth.finishDeviceLogin(device)
                try await accept(credential, login: id)
            } catch { loginFailed(error, id: id) }
        }
    }

    func signInWithBrowser() {
        cancelLogin()
        error = nil
        isLoggingIn = true
        browserLogin = oauth.startBrowserLogin()
        let id = loginID
        loginTask = Task {
            do {
                try await Task.sleep(for: .seconds(600))
                loginFailed(CodexError.loginExpired, id: id)
            } catch { /* cancellation closes only this attempt */ }
        }
    }

    func finishBrowser(callback: String) {
        guard let browserLogin else { return }
        loginTask?.cancel()
        let id = loginID
        error = nil
        loginTask = Task {
            do {
                let credential = try await oauth.finishBrowserLogin(browserLogin, callback: callback)
                try await accept(credential, login: id)
            } catch { loginFailed(error, id: id) }
        }
    }

    func cancelLogin() {
        loginID = UUID()
        loginTask?.cancel()
        loginTask = nil
        isLoggingIn = false
        deviceLogin = nil
        browserLogin = nil
    }

    func importLogin(from url: URL) async {
        cancelLogin()
        error = nil
        let id = loginID
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_048_576 else { throw CodexError.invalidCredential }
            let credential = try CodexCredential.importing(Data(contentsOf: url))
            try await accept(credential, login: id)
        } catch {
            guard id == loginID else { return }
            // File paths, grant contents and response bodies never enter UI errors.
            self.error = (error as? CodexError)?.localizedDescription ?? "Could not import this login file."
        }
    }

    func signOut() async {
        cancelLogin()
        accountRevision = UUID()
        error = nil
        loadingUsage = false
        do {
            try await CodexKeychain.credentials.replace(nil)
            show(nil)
            usage = nil
            usageError = nil
            loadingUsage = false
        } catch { self.error = error.localizedDescription }
    }

    func refreshUsage(force: Bool = false) async {
        guard isSignedIn, !loadingUsage else { return }
        if !force, let usage, Date.now.timeIntervalSince(usage.updatedAt) < 60 { return }
        let revision = accountRevision
        loadingUsage = true
        usageError = nil
        do {
            let result = try await CodexUsage.fetch(credentials: CodexKeychain.credentials)
            guard revision == accountRevision else { return }
            usage = result
        } catch {
            guard revision == accountRevision else { return }
            usageError = "Usage is unavailable. Your saved login has not been removed."
        }
        guard revision == accountRevision else { return }
        loadingUsage = false
        await refreshStatus()
    }

    private func accept(_ credential: CodexCredential, login id: UUID) async throws {
        try Task.checkCancellation()
        guard id == loginID else { throw CancellationError() }
        let revision = await CodexKeychain.credentials.revision()
        guard id == loginID else { throw CancellationError() }
        try await CodexKeychain.credentials.replace(credential, ifRevision: revision)
        guard id == loginID else { return }
        accountRevision = UUID()
        usage = nil
        usageError = nil
        loadingUsage = false
        show(credential)
        isLoggingIn = false
        deviceLogin = nil
        browserLogin = nil
        error = nil
    }

    private func show(_ credential: CodexCredential?) {
        isSignedIn = credential != nil
        accountLabel = credential.map { $0.email ?? $0.accountId }
        expiresAt = credential.map { Date(timeIntervalSince1970: $0.expires / 1000) }
    }

    private func loginFailed(_ failure: Error, id: UUID) {
        guard id == loginID else { return }
        isLoggingIn = false
        deviceLogin = nil
        browserLogin = nil
        if !(failure is CancellationError) { error = failure.localizedDescription }
    }
}
