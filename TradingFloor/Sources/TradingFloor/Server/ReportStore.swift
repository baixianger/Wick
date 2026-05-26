import Foundation

/// Shared report cache. The fixed-flow report for a (ticker, trading-day) is
/// non-personal — same for everyone — so the server stores it once and serves
/// it to all users. Swap the concrete store for Postgres in production; the
/// protocol is all `ReportService` depends on.
public protocol ReportStore: Sendable {
    func report(ticker: String, tradingDay: String) async -> Report?
    func save(_ report: Report, tradingDay: String) async
    /// Most-recent-first list of prior reports for a ticker, excluding the
    /// optional `excluding` trading day (the one currently being generated).
    /// Used by the workflow agent to feed self-conditioning history into the
    /// trader prompt — see live-trade-bench's history-in-prompt trick.
    func recent(ticker: String, limit: Int, excluding: String?) async -> [Report]
}

public enum TradingDay {
    /// Calendar-day key, UTC. One shared report per ticker per day.
    public static func key(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

/// Process-memory store — fine for tests and a single-node MVP.
public actor InMemoryReportStore: ReportStore {
    private var reports: [String: Report] = [:]
    public init() {}

    public func report(ticker: String, tradingDay: String) async -> Report? {
        reports[Self.id(ticker, tradingDay)]
    }
    public func save(_ report: Report, tradingDay: String) async {
        reports[Self.id(report.ticker, tradingDay)] = report
    }
    public func recent(ticker: String, limit: Int, excluding: String? = nil) async -> [Report] {
        let prefix = "\(ticker.uppercased())-"
        let excludeKey = excluding.map { Self.id(ticker, $0) }
        return reports
            .filter { $0.key.hasPrefix(prefix) && $0.key != excludeKey }
            .map { $0.value }
            .sorted { $0.asOf > $1.asOf }
            .prefix(max(0, limit))
            .map { $0 }
    }
    private static func id(_ ticker: String, _ day: String) -> String {
        "\(ticker.uppercased())-\(day)"
    }
}

/// JSON-on-disk store — survives restarts on a single node without a DB.
public actor DiskReportStore: ReportStore {
    private let directory: URL
    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func report(ticker: String, tradingDay: String) async -> Report? {
        let url = directory.appendingPathComponent(file(ticker, tradingDay))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Report.self, from: data)
    }
    public func save(_ report: Report, tradingDay: String) async {
        let url = directory.appendingPathComponent(file(report.ticker, tradingDay))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report) { try? data.write(to: url) }
    }
    public func recent(ticker: String, limit: Int, excluding: String? = nil) async -> [Report] {
        let prefix = "\(ticker.uppercased())-"
        let excludeFile = excluding.map { file(ticker, $0) }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") && $0 != excludeFile }
            .compactMap { name -> Report? in
                let url = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Report.self, from: data)
            }
            .sorted { $0.asOf > $1.asOf }
            .prefix(max(0, limit))
            .map { $0 }
    }
    private func file(_ ticker: String, _ day: String) -> String {
        "\(ticker.uppercased())-\(day).json"
    }
}
