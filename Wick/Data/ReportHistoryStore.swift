import Foundation
import Observation
import TradingFloor

/// All historical desk-run `Report`s the user has ever generated /
/// received on this device. The AI tab reads this on appear and shows
/// the per-ticker history as its default surface, so the user lands on
/// "what's been analyzed before" rather than a cold "Run analysis" CTA.
///
/// Persistence is a single JSON array on disk — small enough (kilobytes
/// per report, a few dozen reports realistically) that an atomic
/// rewrite on save is the right shape. Server vs local runs all flow
/// through the same store; the source isn't recorded (the report
/// itself doesn't differ).
@MainActor
@Observable
final class ReportHistoryStore {

    /// All reports, sorted newest-first by `generatedAt`. Replaced
    /// wholesale on save / load — small data, simple invariants.
    private(set) var reports: [Report]

    /// Per-symbol `DeskRunner` cache. Kept on the history store so a
    /// run started on AAPL survives the user navigating to NVDA and
    /// back — the AITab view is `.id(ticker.id)`-rebuilt, so a runner
    /// stored as `@State` inside the view would be discarded mid-run
    /// and its `onCompleted` callback would lose the history binding.
    /// Lazily created on first access per symbol.
    private var runners: [String: DeskRunner] = [:]

    init() {
        let loaded = Self.loadFromDisk()
        self.reports = loaded.sorted { $0.generatedAt > $1.generatedAt }
    }

    // MARK: - Runner factory

    /// Resolve (or create) the desk runner for `symbol`. Idempotent —
    /// subsequent calls return the same instance, so SwiftUI's
    /// `@Observable` tracking on the runner's `phase` continues to
    /// drive view updates across AITab remounts.
    ///
    /// The returned runner's `onCompleted` is wired to `save(_:)` so
    /// completions land in history even when no AITab is mounted for
    /// that ticker at the moment the run finishes.
    func runner(for symbol: String) -> DeskRunner {
        let key = symbol.uppercased()
        if let existing = runners[key] { return existing }
        let runner = DeskRunner()
        runner.onCompleted = { [weak self] report in
            self?.save(report)
        }
        runners[key] = runner
        return runner
    }

    // MARK: - Queries

    /// History for `ticker`, newest first. Case-insensitive symbol match.
    func reports(for ticker: String) -> [Report] {
        let needle = ticker.uppercased()
        return reports.filter { $0.ticker.uppercased() == needle }
    }

    func hasHistory(for ticker: String) -> Bool {
        let needle = ticker.uppercased()
        return reports.contains { $0.ticker.uppercased() == needle }
    }

    // MARK: - Mutations

    /// Append + persist. Deduplicates by (ticker, generatedAt) so a
    /// stale server poll that returns the same row twice doesn't bloat
    /// the list.
    func save(_ report: Report) {
        let key = Self.key(for: report)
        if reports.contains(where: { Self.key(for: $0) == key }) { return }
        reports.insert(report, at: 0)
        reports.sort { $0.generatedAt > $1.generatedAt }
        persist()
    }

    func delete(_ report: Report) {
        let key = Self.key(for: report)
        reports.removeAll { Self.key(for: $0) == key }
        persist()
    }

    private static func key(for report: Report) -> String {
        let day = ISO8601DateFormatter().string(from: report.generatedAt)
        return "\(report.ticker.uppercased())|\(day)"
    }

    // MARK: - Persistence

    private static var storeURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Wick", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reports.json")
    }

    private static func loadFromDisk() -> [Report] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Report].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(reports) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
