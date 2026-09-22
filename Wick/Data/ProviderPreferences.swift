import Foundation

/// Shared loading policy for startup and provider switches. Defaults apply
/// only before setup; switching must preserve saved endpoints and model IDs.
struct ProviderPreferences {
    let baseURL: String
    let quickModel: String
    let deepModel: String

    init(kind: ProviderKind, defaults: UserDefaults = .standard) {
        let prefix = "tf.byo.\(kind.rawValue)"
        baseURL = defaults.string(forKey: "\(prefix).baseURL") ?? kind.defaultBaseURL
        quickModel = defaults.string(forKey: "\(prefix).quickModel") ?? kind.defaultQuickModel
        deepModel = defaults.string(forKey: "\(prefix).deepModel") ?? kind.defaultDeepModel
    }
}
