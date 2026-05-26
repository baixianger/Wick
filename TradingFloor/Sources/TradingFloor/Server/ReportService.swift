import Foundation

/// The server brain. Given a ticker, it returns the shared report for today —
/// from cache if present, otherwise it generates one. The crucial property is
/// **single-flight**: if 1000 users ask for NVDA at once, only ONE desk run
/// happens and everyone awaits its result. That's what makes the per-report
/// cost amortize across the whole userbase.
public actor ReportService {
    private let desk: TradingFloor
    private let store: any ReportStore
    private var inFlight: [String: Task<Report, Error>] = [:]

    public init(desk: TradingFloor, store: any ReportStore) {
        self.desk = desk
        self.store = store
    }

    public func report(ticker: String, asOf: Date = .now) async throws -> Report {
        let symbol = ticker.uppercased()
        let day = TradingDay.key(asOf)
        let key = "\(symbol)-\(day)"

        // Join an in-progress run for the same key, if any. Checking and
        // registering happen with no `await` in between, so concurrent callers
        // in the same actor reliably collapse onto one task.
        if let task = inFlight[key] { return try await task.value }

        let task = Task { [desk, store] in
            if let cached = await store.report(ticker: symbol, tradingDay: day) {
                return cached
            }
            let report = try await desk.analyze(ticker: symbol, asOf: asOf)
            await store.save(report, tradingDay: day)
            return report
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Cache-only lookup (the `GET` path): never triggers a run.
    public func cached(ticker: String, asOf: Date = .now) async -> Report? {
        await store.report(ticker: ticker.uppercased(), tradingDay: TradingDay.key(asOf))
    }
}
