import Foundation
import Testing
@testable import Wick

struct ProviderPreferencesTests {
    @Test func provider_round_trip_keeps_custom_endpoints_and_models() throws {
        let name = "wick-provider-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for kind in [ProviderKind.custom, .codex] {
            defaults.set("https://\(kind.rawValue).example.test/v1", forKey: "tf.byo.\(kind.rawValue).baseURL")
            defaults.set("\(kind.rawValue)-quick", forKey: "tf.byo.\(kind.rawValue).quickModel")
            defaults.set("\(kind.rawValue)-deep", forKey: "tf.byo.\(kind.rawValue).deepModel")
        }
        // The same loader is used for initial launch and provider switching.
        for kind in [ProviderKind.custom, .codex, .openai, .custom, .codex] {
            let saved = ProviderPreferences(kind: kind, defaults: defaults)
            if kind == .openai {
                #expect(saved.baseURL == kind.defaultBaseURL)
                #expect(saved.quickModel == kind.defaultQuickModel)
                #expect(saved.deepModel == kind.defaultDeepModel)
            } else {
                #expect(saved.baseURL == "https://\(kind.rawValue).example.test/v1")
                #expect(saved.quickModel == "\(kind.rawValue)-quick")
                #expect(saved.deepModel == "\(kind.rawValue)-deep")
            }
        }
    }

    @Test func explicit_empty_values_are_not_replaced_with_defaults() throws {
        let name = "wick-provider-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("", forKey: "tf.byo.custom.baseURL")
        defaults.set("", forKey: "tf.byo.custom.quickModel")
        let saved = ProviderPreferences(kind: .custom, defaults: defaults)
        #expect(saved.baseURL.isEmpty && saved.quickModel.isEmpty)
        #expect(saved.deepModel == ProviderKind.custom.defaultDeepModel)
    }
}
