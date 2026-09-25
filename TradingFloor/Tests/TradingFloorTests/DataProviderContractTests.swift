import Foundation
import Testing
@testable import TradingFloor

private final class DataProviderStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Dummy keys select a response; no mutable global stub state.
        let key = request.value(forHTTPHeaderField: "X-API-Key")
            ?? request.value(forHTTPHeaderField: "X-Finnhub-Token") ?? ""
        let isNews = request.url!.path.contains("company-news")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let leaked = query.contains { ["token", "apikey", "api_key"].contains($0.name) }
        let status = leaked || key.isEmpty ? 401 : key == "test-quota" ? 429 : 200
        let body: String
        if key == "test-invalid" { body = "{\"unexpected\":true}" }
        else if key == "test-empty" { body = #"{"period_days":7,"stocks":[]}"# }
        else if isNews {
            body = #"[{"headline":"older","datetime":1699999900,"source":"Publisher","url":"https://example.test/old"},{"headline":"newer","datetime":1700000000,"url":"https://example.test/new"},{"headline":"duplicate","datetime":1700000000,"url":"https://example.test/new"},{"headline":"future","datetime":1800000000}]"#
        } else {
            body = #"{"period_days":7,"stocks":[{"ticker":"AAPL","mentions":12,"sentiment_score":null,"buzz_score":30.5}]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func dataSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DataProviderStub.self]
    return URLSession(configuration: config)
}

@Test func finnhub_header_auth_sorts_deduplicates_and_excludes_future() async throws {
    let session = dataSession(); defer { session.invalidateAndCancel() }
    let client = FinnhubClient(apiKey: "test-valid", session: session)
    let items = try await client.articles(symbol: "AAPL", asOf: Date(timeIntervalSince1970: 1700000000))
    #expect(items.map(\.title) == ["newer", "older"])
    #expect(items.last?.publisher == "Publisher")
}

@Test func data_provider_distinguishes_quota_and_bad_schema() async {
    let session = dataSession(); defer { session.invalidateAndCancel() }
    await #expect(throws: DataAPIError.quota) {
        try await FinnhubClient(apiKey: "test-quota", session: session).articles(symbol: "AAPL")
    }
    await #expect(throws: DataAPIError.invalidResponse) {
        try await AdanosClient(apiKey: "test-invalid", session: session).stock(symbol: "AAPL")
    }
}

@Test func adanos_missing_score_is_not_neutral_and_empty_is_no_coverage() async throws {
    let session = dataSession(); defer { session.invalidateAndCancel() }
    let value = try await AdanosClient(apiKey: "test-valid", session: session).stock(symbol: "aapl")
    #expect(value?.mentions == 12)
    #expect(value?.sentiment_score == nil)
    let empty = try await AdanosClient(apiKey: "test-empty", session: session).stock(symbol: "AAPL")
    #expect(empty == nil)
}

@Test func adanos_rejects_unsupported_format_before_request() async {
    let session = dataSession(); defer { session.invalidateAndCancel() }
    await #expect(throws: DataAPIError.unsupportedSymbol) {
        try await AdanosClient(apiKey: "test-valid", session: session).stock(symbol: "0700.HK")
    }
}
