import Foundation

/// Async status of a report job — what the HTTP layer returns.
public enum JobPhase: String, Sendable, Codable {
    case queued, running, done, failed
}

public struct JobStatus: Sendable, Codable {
    public let phase: JobPhase
    public let report: Report?
    public let error: String?

    public init(phase: JobPhase, report: Report? = nil, error: String? = nil) {
        self.phase = phase
        self.report = report
        self.error = error
    }
}

/// Job queue + bounded worker pool. A request checks the store; on a miss it
/// enqueues a job (deduplicated per ticker/day) and returns immediately with
/// `.queued`. Up to `maxWorkers` agents run concurrently, pulling from the
/// queue — the agent IS the worker. The HTTP layer never blocks on a run.
///
/// This is the single-node version (vertical scale via `maxWorkers`). For
/// horizontal scale, back `pending`/`states` with Redis/Postgres so multiple
/// server instances share one queue — the `submit`/`status` surface stays the
/// same.
public actor ReportQueue {
    private let desk: TradingFloor
    private let store: any ReportStore
    private let maxWorkers: Int

    private var states: [String: JobStatus] = [:]
    private var pending: [(key: String, ticker: String, asOf: Date, day: String)] = []
    private var running = 0

    public init(desk: TradingFloor, store: any ReportStore, maxWorkers: Int = 4) {
        self.desk = desk
        self.store = store
        self.maxWorkers = max(1, maxWorkers)
    }

    /// Read-or-enqueue. Returns the current status (possibly `.done` on a hit).
    public func submit(ticker: String, asOf: Date = .now) async -> JobStatus {
        let symbol = ticker.uppercased()
        let day = TradingDay.key(asOf)
        let key = "\(symbol)-\(day)"

        if let known = states[key] { return known }

        // Cross-process/cross-restart hit: a worker elsewhere already saved it.
        if let cached = await store.report(ticker: symbol, tradingDay: day) {
            let status = JobStatus(phase: .done, report: cached)
            states[key] = status
            return status
        }
        // Re-check after the await above — another submit may have enqueued it.
        if let known = states[key] { return known }

        let queued = JobStatus(phase: .queued)
        states[key] = queued
        pending.append((key, symbol, asOf, day))
        pump()
        return queued
    }

    /// Status without enqueuing (the GET path).
    public func status(ticker: String, asOf: Date = .now) -> JobStatus? {
        states["\(ticker.uppercased())-\(TradingDay.key(asOf))"]
    }

    // MARK: - Worker pool

    /// Start as many workers as capacity allows.
    private func pump() {
        while running < maxWorkers, !pending.isEmpty {
            let job = pending.removeFirst()
            running += 1
            states[job.key] = JobStatus(phase: .running)
            Task { await self.work(job) }
        }
    }

    private func work(_ job: (key: String, ticker: String, asOf: Date, day: String)) async {
        do {
            let report = try await desk.analyze(ticker: job.ticker, asOf: job.asOf)
            await store.save(report, tradingDay: job.day)
            states[job.key] = JobStatus(phase: .done, report: report)
        } catch {
            states[job.key] = JobStatus(phase: .failed, error: String(describing: error))
        }
        running -= 1
        pump()   // a slot freed — pull the next job
    }
}
