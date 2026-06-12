import Foundation

/// Phase-1 internationalization — a deliberately tiny, pure-code localization
/// layer. No String Catalog, no `.lproj`, no pbxproj resource wiring: the two
/// language strings live AT THE CALL SITE via `L("English", "中文")`, and a
/// single global flag decides which one is returned.
///
/// Runtime switching is achieved by the host (`WickApp`) setting
/// `appUILanguageIsChinese` when the user picks a language AND forcing a full
/// view-tree rebuild via `.id(language)`, so every `L(...)` re-evaluates.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, zh, en
    var id: String { rawValue }
}

/// Resolved UI language (never `.system`) — read by the `L()` helper. Set by the
/// host when the setting changes; global so the free `L(_:_:)` function can read
/// it without threading a binding through every view.
nonisolated(unsafe) var appUILanguageIsChinese: Bool = {
    // Initial resolve from the system's preferred language.
    (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
}()

/// Inline bilingual literal — returns the active language's string. Translations
/// live AT THE CALL SITE (no key scheme, no catalog): `Text(L("Overview", "概览"))`.
func L(_ en: String, _ zh: String) -> String { appUILanguageIsChinese ? zh : en }
