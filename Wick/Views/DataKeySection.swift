import SwiftUI
import TradingFloor

/// Native Settings form with an unpersisted draft and explicit commit.
struct DataKeySection: View {
    @Bindable var settings: AgentSettings
    let provider: String
    @State private var draft = ""
    @State private var message: String?
    @State private var testing = false
    @State private var request: Task<Void, Never>?
    @State private var generation = UUID()

    private var isFinnhub: Bool { provider == "finnhub" }
    private var name: String { isFinnhub ? "Finnhub" : "Adanos" }
    private var saved: String { isFinnhub ? settings.finnhubKey : settings.adanosKey }

    var body: some View {
        Section(name) {
            Text(LocalizedStringKey(isFinnhub ? "Company news" : "Reddit sentiment aggregates"))
            Text(LocalizedStringKey(saved.isEmpty ? "No API key saved" : "API key saved in Keychain"))
                .foregroundStyle(.secondary)
            SecureField("New API key", text: $draft)
                .autocorrectionDisabled()
                .onSubmit { save() }
                .onChange(of: draft) { _, _ in invalidate() }
            HStack {
                Button("Save") { save() }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Test saved key") { test() }.disabled(saved.isEmpty || testing || !draft.isEmpty)
                Button("Remove key", role: .destructive) {
                    invalidate()
                    do { try settings.saveDataKey("", provider: provider); draft = "" }
                    catch { message = error.localizedDescription }
                }.disabled(saved.isEmpty)
                if testing { ProgressView().controlSize(.small).accessibilityLabel("Testing connection") }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            Text(LocalizedStringKey(isFinnhub
                 ? "Optional US company news. Yahoo remains the fallback when Finnhub has no headlines or is unavailable."
                 : "Optional Reddit aggregates for supported US tickers. Loaded on request, cached for five minutes. Each uncached load or connection test uses one API request."))
                .font(.caption).foregroundStyle(.secondary)
            Text("Keys stay in this Mac’s Keychain. Data requests go directly to the provider. Your plan’s coverage, quotas and usage terms apply.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Manage API key and plan", destination: URL(string: isFinnhub ? "https://finnhub.io/dashboard" : "https://adanos.org/register")!)
        }
        .onDisappear { invalidate() }
    }

    private func invalidate() {
        request?.cancel()
        generation = UUID()
        testing = false
        message = nil
    }
    private func save() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        invalidate()
        do { try settings.saveDataKey(draft, provider: provider); draft = "" }
        catch { message = error.localizedDescription }
    }
    private func test() {
        invalidate()
        testing = true
        let id = generation
        let key = saved
        request = Task {
            let result: String
            do {
                if isFinnhub { _ = try await FinnhubClient(apiKey: key).articles(symbol: "AAPL", limit: 1) }
                else { _ = try await AdanosClient(apiKey: key).stock(symbol: "AAPL") }
                result = String(localized: "Connection verified for this endpoint. Other data may require a different plan.", locale: LocaleHolder.current)
            } catch is CancellationError { return }
            catch { result = dataAPIMessage(error) }
            guard !Task.isCancelled, generation == id else { return }
            message = result
            testing = false
        }
    }
}

func dataAPIMessage(_ error: Error) -> String {
    switch error as? DataAPIError {
    case .invalidKey: String(localized: "The provider rejected this API key.", locale: LocaleHolder.current)
    case .forbidden: String(localized: "Your plan does not permit this request.", locale: LocaleHolder.current)
    case .quota: String(localized: "Provider quota reached. Try again later or check your plan.", locale: LocaleHolder.current)
    case .unsupportedSymbol: String(localized: "This source does not support this ticker format.", locale: LocaleHolder.current)
    default: String(localized: "Data unavailable. Check your connection and try again.", locale: LocaleHolder.current)
    }
}
