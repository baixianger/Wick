import Foundation
import OSLog
import Security

/// Generic-password wrapper backed by macOS Keychain (data-protection
/// variant). Applies Apple's recommended attributes for storing user
/// secrets on a sandboxed macOS app:
///
///   - `kSecUseDataProtectionKeychain: true` — opt into the modern
///     data-protection keychain rather than the legacy file-based one.
///     The data-protection keychain is sandbox-aware (items inherit
///     the calling app's access group automatically) and supports the
///     fine-grained `kSecAttrAccessible` constants below.
///   - `kSecAttrService` + `kSecAttrAccount` — the canonical two-key
///     identity for a generic password. Service scopes everything to
///     this app; account distinguishes the specific secret. Without
///     a service, our `account` strings collide in the user's keychain
///     with any other app using the same account label.
///   - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — API keys are
///     "this device only" by design. Stays out of iCloud Keychain and
///     out of any encrypted backup, so a user's credentials don't
///     leak through device restore on a different Mac.
///
/// `save` / `delete` return the raw `OSStatus` so callers can detect
/// failures explicitly. Errors are also logged via `os_log` so they
/// surface in Console.app when something goes wrong in the field.
enum Keychain {

    /// `kSecAttrService` value for every Wick entry. Pairs with the
    /// caller-supplied `account` to form the (service, account)
    /// uniqueness pair the Keychain Services API expects.
    private static let service = "Wick"

    /// Subsystem-scoped logger so Keychain trouble is grep-able in
    /// Console.app (`subsystem == "me.impai.wick" && category == "Keychain"`).
    private static let log = Logger(subsystem: "me.impai.wick", category: "Keychain")

    /// Save (insert-or-replace) a string value under `account`. Returns
    /// `errSecSuccess` on the happy path; any other status indicates a
    /// real failure (logged at the error level).
    @discardableResult
    static func save(_ value: String, account: String) -> OSStatus {
        let data = Data(value.utf8)
        // Update in place: a failed write must not destroy the saved key.
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary,
                                        [kSecValueData as String: data] as CFDictionary)
        if updateStatus != errSecItemNotFound {
            if updateStatus != errSecSuccess {
                log.error("update failed for \(account, privacy: .public): status \(updateStatus)")
            }
            return updateStatus
        }
        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            log.error("save failed for \(account, privacy: .public): \(message(for: addStatus), privacy: .public) (status \(addStatus))")
        }
        return addStatus
    }

    /// Load the string value stored under `account`, if any. Returns
    /// `nil` for both "not found" and any other read failure (those
    /// are logged but indistinguishable to callers — there's nothing
    /// they can do with the difference).
    static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                log.error("load decode failed for \(account, privacy: .public)")
                return nil
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            log.error("load failed for \(account, privacy: .public): \(message(for: status), privacy: .public) (status \(status))")
            return nil
        }
    }

    @discardableResult
    static func delete(account: String) -> OSStatus {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("delete failed for \(account, privacy: .public): \(message(for: status), privacy: .public) (status \(status))")
        }
        return status
    }

    /// One-shot rescue for items written under earlier Wick builds
    /// that DID NOT include `kSecAttrService: "Wick"` or
    /// `kSecUseDataProtectionKeychain: true` in the save query. Those
    /// entries live in the legacy file-based keychain with no
    /// service attribute and are invisible to the new `baseQuery`.
    ///
    /// Call this once at app launch (gated by a UserDefaults flag).
    /// For each `account` we expect to own, we run a fallback query
    /// (no service, no data-protection flag), pull the value, and
    /// re-save it via the modern `save(_:account:)` path — which
    /// inserts under the new schema. The legacy item is left in
    /// place (no risk of data loss if we ever roll back).
    ///
    /// Returns the number of accounts successfully recovered.
    @discardableResult
    static func migrateLegacyEntriesIfNeeded(accounts: [String],
                                             flagKey: String = "wick.keychain.legacy-migrated.v1"
    ) -> Int {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: flagKey) == false else { return 0 }
        var recovered = 0
        for account in accounts {
            // Skip accounts that already have a value under the new schema.
            if load(account: account) != nil { continue }
            // Legacy query: no `kSecAttrService`, no
            // `kSecUseDataProtectionKeychain`. Matches what the prior
            // build's save() produced.
            let legacyQuery: [String: Any] = [
                kSecClass as String:        kSecClassGenericPassword,
                kSecAttrAccount as String:  account,
                kSecReturnData as String:   true,
                kSecMatchLimit as String:   kSecMatchLimitOne,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let value = String(data: data, encoding: .utf8)
            else { continue }
            // Re-save under the new schema. The legacy entry stays.
            if save(value, account: account) == errSecSuccess {
                recovered += 1
                log.info("recovered legacy keychain entry for \(account, privacy: .public)")
            }
        }
        defaults.set(true, forKey: flagKey)
        return recovered
    }

    // MARK: - Helpers

    /// Common attribute set used by every save / load / delete query.
    /// Centralised so the (service, account, data-protection, class)
    /// quadruple stays in sync across operations — mismatched attrs
    /// between save and load would silently miss the entry.
    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String:                kSecClassGenericPassword,
            kSecAttrService as String:          service,
            kSecAttrAccount as String:          account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Human-readable error string for an `OSStatus`. Falls back to
    /// `"unknown"` when `SecCopyErrorMessageString` returns nil (rare,
    /// but possible on private-API status codes).
    private static func message(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "unknown"
    }
}
