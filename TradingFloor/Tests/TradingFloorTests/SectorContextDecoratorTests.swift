import Testing
import Foundation
@testable import TradingFloor

// MARK: - URLProtocol mock for push2delay

final class SectorMockURLProtocol: URLProtocol, @unchecked Sendable {
    /// secid → canned `data` body
    nonisolated(unsafe) static var indices: [String: [String: Any]] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.contains("eastmoney.com") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let secid = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "secid" })?.value ?? ""
        let payload: [String: Any] = Self.indices[secid].map { ["data": $0] }
            ?? ["data": NSNull()]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let resp = HTTPURLResponse(url: url, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [SectorMockURLProtocol.self]
    return URLSession(configuration: cfg)
}

private struct StubBase: MarketDataProvider {
    func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        MarketSnapshot(symbol: symbol, asOf: asOf, lastPrice: 100,
                       priceSummary: "", technicals: "",
                       fundamentals: [:], news: [], macro: "")
    }
}

// MARK: - Tests

@Suite(.serialized)
struct SectorContextDecoratorTests {

    private func seedCSI300() {
        SectorMockURLProtocol.indices["1.000300"] = [
            "f43": 4914.21,
            "f58": "沪深300",
            "f170": 0.12,
            "f171": 1.61
        ]
    }
    private func seedHSI() {
        SectorMockURLProtocol.indices["100.HSI"] = [
            "f43": 25006.16,
            "f58": "恒生指数",
            "f170": -1.27,
            "f171": 1.99
        ]
    }
    private func seedSPX() {
        SectorMockURLProtocol.indices["100.SPX"] = [
            "f43": 7563.63,
            "f58": "标普500",
            "f170": 0.58,
            "f171": 0.81
        ]
    }

    @Test func a_share_routes_to_csi300() async throws {
        SectorMockURLProtocol.indices = [:]
        seedCSI300()
        defer { SectorMockURLProtocol.indices = [:] }

        let dec = SectorContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.macro.contains("沪深300"))
        #expect(s.macro.contains("4914.21"))
        #expect(s.macro.contains("+0.12% today"))
        #expect(s.macro.contains("from 52w high"))
    }

    @Test func hk_routes_to_hsi() async throws {
        SectorMockURLProtocol.indices = [:]
        seedHSI()
        defer { SectorMockURLProtocol.indices = [:] }

        let dec = SectorContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "0700.HK", asOf: Date())
        #expect(s.macro.contains("恒生指数"))
        #expect(s.macro.contains("-1.27% today"))
    }

    @Test func us_routes_to_spx() async throws {
        SectorMockURLProtocol.indices = [:]
        seedSPX()
        defer { SectorMockURLProtocol.indices = [:] }

        let dec = SectorContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "NVDA", asOf: Date())
        #expect(s.macro.contains("标普500"))
        #expect(s.macro.contains("+0.58% today"))
    }

    @Test func appends_to_existing_macro_instead_of_overwriting() async throws {
        SectorMockURLProtocol.indices = [:]
        seedCSI300()
        defer { SectorMockURLProtocol.indices = [:] }

        struct PreloadedBase: MarketDataProvider {
            func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
                MarketSnapshot(symbol: symbol, asOf: asOf,
                               priceSummary: "", technicals: "",
                               fundamentals: [:], news: [],
                               macro: "CPI YoY +1.2%; PMI 制造业 50.3")
            }
        }
        let dec = SectorContextDecorator(base: PreloadedBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.macro.contains("CPI YoY"))           // preserved
        #expect(s.macro.contains("沪深300"))            // appended
        // Two distinct lines now.
        #expect(s.macro.split(separator: "\n").count == 2)
    }

    @Test func caches_per_day_so_second_call_skips_network() async throws {
        SectorMockURLProtocol.indices = [:]
        seedCSI300()
        let dec = SectorContextDecorator(base: StubBase(), session: mockSession())
        let day = Date()
        let first = try await dec.snapshot(symbol: "600519.SS", asOf: day)
        #expect(first.macro.contains("沪深300"))

        // Wipe the mock — the cached value must still surface.
        SectorMockURLProtocol.indices = [:]
        let second = try await dec.snapshot(symbol: "000001.SZ", asOf: day)
        #expect(second.macro.contains("沪深300"))
    }

    @Test func failure_to_fetch_index_silently_drops_section() async throws {
        // No handler registered → mock returns data:NSNull → provider
        // returns nil → render produces empty line → snapshot.macro
        // stays whatever the base produced (here: empty).
        SectorMockURLProtocol.indices = [:]
        let dec = SectorContextDecorator(base: StubBase(), session: mockSession())
        let s = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
        #expect(s.macro.isEmpty)
    }
}

// MARK: - Live smoke

@Test(.disabled(if: ProcessInfo.processInfo.environment["EASTMONEY_LIVE"] == nil))
func sector_context_live_smoke() async throws {
    let dec = SectorContextDecorator(base: StubMarketDataProvider())
    let a = try await dec.snapshot(symbol: "600519.SS", asOf: Date())
    print("[LIVE-SEC] 600519.SS macro=\(a.macro)")
    #expect(a.macro.contains("沪深300"))

    let h = try await dec.snapshot(symbol: "0700.HK", asOf: Date())
    print("[LIVE-SEC] 0700.HK macro=\(h.macro)")
    #expect(h.macro.contains("恒生指数"))

    let u = try await dec.snapshot(symbol: "NVDA", asOf: Date())
    print("[LIVE-SEC] NVDA macro=\(u.macro)")
    #expect(u.macro.contains("标普500"))
}
