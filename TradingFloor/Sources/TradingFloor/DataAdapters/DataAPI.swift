import Foundation

/// Deliberately excludes response bodies and URLs from user-facing errors.
public enum DataAPIError: String, Error, Sendable {
    case invalidKey, forbidden, quota, unavailable, invalidResponse, unsupportedSymbol
}

extension DataAPIError: LocalizedError {
    public var errorDescription: String? { rawValue }
}

public enum DataAPI {
    public static func fetch(_ request: URLRequest, session: URLSession) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw DataAPIError.invalidResponse }
            switch http.statusCode {
            case 200..<300: return data
            case 401: throw DataAPIError.invalidKey
            case 403: throw DataAPIError.forbidden
            case 429: throw DataAPIError.quota
            default: throw DataAPIError.unavailable
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as DataAPIError { throw error }
        catch { throw DataAPIError.unavailable }
    }

    public static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
