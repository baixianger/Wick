import SwiftUI
import TradingFloor

struct AdanosSection: View {
    let symbol: String
    @Environment(AgentRuntime.self) private var runtime
    @Environment(AgentSettings.self) private var settings
    @State private var stock: AdanosStock?
    @State private var message: String?
    @State private var loading = false
    @State private var requested = false
    @State private var loadedAt: Date?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if settings.adanosKey.isEmpty {
                    Text("Add an Adanos API key in Settings → Data Sources to view Reddit aggregates.")
                } else {
                    HStack {
                        Button("Load sentiment") { load() }.disabled(loading)
                        if loading { ProgressView().controlSize(.small) }
                    }
                    if let stock {
                        LabeledContent("Mentions", value: stock.mentions.map { String($0) } ?? "—")
                        LabeledContent("Sentiment (−1…1)", value: stock.sentiment_score.map { String(format: "%.2f", $0) } ?? "—")
                        LabeledContent("Buzz score", value: stock.buzz_score.map { String(format: "%.1f", $0) } ?? "—")
                    } else if requested && !loading && message == nil {
                        Text("No qualifying Reddit data for this period.")
                    }
                    if let message { Text(message).foregroundStyle(.secondary) }
                    if let loadedAt {
                        Text("UTC window: \(DataAPI.day(loadedAt.addingTimeInterval(-6 * 86_400))) – \(DataAPI.day(loadedAt))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Reddit only · seven UTC calendar days · cached for five minutes. Missing data is not neutral sentiment.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Adanos · Reddit", systemImage: "chart.bar.xaxis") }
        .onChange(of: symbol) { _, _ in reset() }
        .onChange(of: settings.dataCredentialsRevision) { _, _ in reset() }
        .onDisappear { reset() }
    }

    private func reset() {
        task?.cancel(); generation = UUID(); loading = false
        requested = false; stock = nil; message = nil; loadedAt = nil
    }
    private func load() {
        reset()
        guard let client = runtime.adanos else { return }
        loading = true; requested = true
        let id = generation
        let date = Date()
        task = Task {
            do {
                let result = try await client.stock(symbol: symbol, asOf: date)
                guard !Task.isCancelled, generation == id else { return }
                stock = result; loadedAt = date
            } catch {
                guard !Task.isCancelled, generation == id else { return }
                message = dataAPIMessage(error)
            }
            loading = false
        }
    }
}
