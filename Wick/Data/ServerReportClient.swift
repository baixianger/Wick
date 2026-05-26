import Foundation
import TradingFloor

/// Talks to WickServer: POST to enqueue (or hit the shared cache), then poll
/// until the job finishes. Lets the app consume the shared, server-generated
/// report instead of running the desk locally — no LLM key needed on-device.
struct ServerReportClient {
    let baseURL: URL
    var session: URLSession = .shared

    enum ClientError: LocalizedError {
        case server(String)
        var errorDescription: String? {
            switch self { case .server(let m): "Server: \(m)" }
        }
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    /// Enqueue + poll to completion. `onStage` reports queued/running.
    func report(ticker: String, onStage: (@Sendable (String) -> Void)? = nil) async throws -> Report {
        // 1. POST /report?ticker= — returns done (cache hit) or queued/running.
        var post = URLComponents(url: baseURL.appendingPathComponent("report"),
                                 resolvingAgainstBaseURL: false)!
        post.queryItems = [.init(name: "ticker", value: ticker)]
        var request = URLRequest(url: post.url!)
        request.httpMethod = "POST"
        var status = try await send(request)

        // 2. Poll GET /report/:ticker/:date until terminal.
        let day = TradingDay.key(.now)
        let getURL = baseURL.appendingPathComponent("report/\(ticker.uppercased())/\(day)")
        while true {
            switch status.phase {
            case .done:
                if let report = status.report { return report }
                throw ClientError.server("done but no report")
            case .failed:
                throw ClientError.server(status.error ?? "job failed")
            case .queued, .running:
                onStage?(status.phase.rawValue)
                try await Task.sleep(for: .seconds(2))
                status = try await send(URLRequest(url: getURL))
            }
        }
    }

    private func send(_ request: URLRequest) async throws -> JobStatus {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.server("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.server("HTTP \(http.statusCode)")
        }
        return try Self.decoder.decode(JobStatus.self, from: data)
    }
}
