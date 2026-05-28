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
        // Remove the JSON file from the shared store too — `persist()`
        // only ever ADDS files, so without this the deleted row would
        // reappear on the next `reloadFromDisk()`.
        SharedStore.deleteReport(report)
    }

    private static func key(for report: Report) -> String {
        let day = ISO8601DateFormatter().string(from: report.generatedAt)
        return "\(report.ticker.uppercased())|\(day)"
    }

    // MARK: - Persistence
    //
    // Reports live in the shared App-Group container (one JSON file per
    // report). That way the bundled `wick-mcp` helper can write a report
    // via the `wick.write_report` MCP tool and the GUI's history list
    // picks it up the next time it reads — closing the loop where an
    // external agent's analysis appears here as if Wicker had run it.
    // See `SharedStore.reports()` / `SharedStore.appendReport(_:)`.

    private static func loadFromDisk() -> [Report] {
        // Migrate the legacy single-file store into the per-file App
        // Group directory on first launch after this change. Idempotent.
        migrateLegacyReportsIfNeeded()
        return SharedStore.reports()
    }

    /// Older builds wrote one big `reports.json` to
    /// `~/Library/Application Support/Wick/reports.json`. Read it once,
    /// fan its rows into the shared per-file directory, then leave the
    /// old file in place (we don't delete it — easier rollback path).
    private static func migrateLegacyReportsIfNeeded() {
        let ud = UserDefaults.standard
        let flagKey = SharedStore.Keys.reportsMigrated
        guard ud.bool(forKey: flagKey) == false else { return }
        defer { ud.set(true, forKey: flagKey) }

        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil, create: false)
        else { return }
        let legacy = base
            .appendingPathComponent("Wick", isDirectory: true)
            .appendingPathComponent("reports.json")
        guard let data = try? Data(contentsOf: legacy) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let rows = try? decoder.decode([Report].self, from: data) else { return }
        for r in rows { SharedStore.appendReport(r) }
    }

    private func persist() {
        // We can't bulk-replace the on-disk set anymore (it lives across
        // many files), so persist deltas: any report we're holding that
        // isn't already in the shared directory gets appended.
        // `SharedStore.appendReport` itself is dedup-safe.
        for r in reports {
            SharedStore.appendReport(r)
        }
    }

    /// Refresh the in-memory list from the shared store. Called from the
    /// GUI's AI tab `onAppear` so an external `wick.write_report` from a
    /// background MCP session shows up without restarting the app.
    /// Always reassigns — `Report` isn't Equatable today and the cost of
    /// a redundant `@Observable` invalidation on a sub-MB list is nil.
    func reloadFromDisk() {
        reports = SharedStore.reports()
    }
}
