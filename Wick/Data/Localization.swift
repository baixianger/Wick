import Foundation

/// App UI language. Backs the Settings → Display → Language picker and drives
/// native String Catalog localization (`Localizable.xcstrings`).
///
/// Runtime switching is achieved by the host (`WickApp`) overriding the SwiftUI
/// environment locale on the roots (`.environment(\.locale, …)`) AND forcing a
/// clean view-tree rebuild via `.id(language)`, so every auto-localized `Text`,
/// `LocalizedStringKey` label and `String(localized:)` helper re-resolves.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, zh, en
    var id: String { rawValue }

    /// The locale to apply to the SwiftUI environment for this choice.
    /// `.system` returns `autoupdatingCurrent` (don't override the user's OS
    /// preference); the explicit cases pin a concrete locale.
    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .zh:     return Locale(identifier: "zh-Hans")
        case .en:     return Locale(identifier: "en")
        }
    }
}

/// Globally-readable resolved UI locale for the handful of non-SwiftUI call
/// sites that localize imperatively via `String(localized:locale:)` (e.g.
/// guardrail / spoken-status / composed strings outside a `Text`). The host
/// updates this whenever the language setting changes, and the `.id(language)`
/// view rebuild forces dependent views to re-evaluate.
enum LocaleHolder {
    nonisolated(unsafe) static var current: Locale = {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
            ? Locale(identifier: "zh-Hans")
            : .autoupdatingCurrent
    }()
}
