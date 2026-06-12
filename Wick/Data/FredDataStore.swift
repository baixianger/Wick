import Foundation
import Observation
import CoreCharts

/// On-demand wrapper around FRED's `series/observations` endpoint —
/// the macro-page equivalent of `LiveDataStore`. Macro tab cards
/// reach in via `series(for:units:fallback:)` and immediately get a
/// synthetic preview while the live fetch lands; once the FRED reply
/// returns, `@Observable` re-renders the card with the real history.
///
/// Distinct from `LiveDataStore` (Yahoo) because:
///   - Symbol space is different (FRED series IDs vs Yahoo tickers)
///   - Endpoint and response shape are different
///   - Auth is required (BYO key, free from FRED website)
///
/// Cache lives for the process lifetime; FRED data updates daily at
/// most, so we don't need a TTL.
@MainActor
@Observable
final class FredDataStore {

    /// FRED API key (BYO). Empty = no fetch, cards stay on synthetic
    /// fallback with a `Source.demo` badge. Updating clears the cache
    /// so the next access refetches against the new key.
    var apiKey: String {
        didSet {
            guard apiKey != oldValue else { return }
            cache.removeAll()
            sources.removeAll()
            inFlight.removeAll()
        }
    }

    enum Source: Equatable {
        case live(fetchedAt: Date)
        case demo                         // no key set, never fetched
        case error(String)                // fetch attempted and failed
    }

    private struct Key: Hashable {
        let seriesID: String
        let units: String
    }

    @ObservationIgnored
    private let session: URLSession = .shared

    private var cache: [Key: CandleSeries] = [:]
    private var sources: [Key: Source] = [:]
    private var inFlight: Set<Key> = []

    init(apiKey: String = "") {
        self.apiKey = apiKey
    }

    // MARK: - Public API

    /// Return the best available series for a FRED series ID.
    /// Synchronous: hits cache, or returns the synthetic `fallback`
    /// while triggering a background fetch.
    ///
    /// `units` follows FRED's units transform set — defaults to `lin`
    /// (linear, no transform). Use `pc1` for "% change from year ago"
    /// (the right transform for CPI to render as YoY inflation).
    func series(for seriesID: String,
                units: String = "lin",
                fallback: CandleSeries) -> CandleSeries
    {
        let key = Key(seriesID: seriesID, units: units)
        if let cached = cache[key] { return cached }
        scheduleFetchIfNeeded(key)
        return fallback
    }

    /// Best label for the source badge — same shape as
    /// `LiveDataStore.source(...)`.
    func source(for seriesID: String, units: String = "lin") -> Source {
        sources[Key(seriesID: seriesID, units: units)] ?? .demo
    }

    // MARK: - Fetching

    private func scheduleFetchIfNeeded(_ key: Key) {
        guard !inFlight.contains(key) else { return }
        guard !apiKey.isEmpty else {
            // CRITICAL: `sources` is `@Observable`-tracked. Writing the
            // same `.demo` value on every body evaluation invalidates
            // the observation and SwiftUI re-renders, which re-enters
            // this code path on the next body call → infinite render
            // loop that locks the main thread (Macro tab "卡死"). Guard
            // the write so it only fires on actual state transitions.
            if sources[key] != .demo {
                sources[key] = .demo
            }
            return
        }
        inFlight.insert(key)
        Task { @MainActor in
            do {
                let series = try await fetch(seriesID: key.seriesID,
                                              units: key.units)
                handleFetchSuccess(key: key, series: series)
            } catch {
                handleFetchFailure(key: key, error: error)
            }
        }
    }

    private func handleFetchSuccess(key: Key, series: CandleSeries) {
        inFlight.remove(key)
        cache[key] = series
        sources[key] = .live(fetchedAt: Date())
    }

    private func handleFetchFailure(key: Key, error: any Error) {
        inFlight.remove(key)
        sources[key] = .error(String(describing: error))
    }

    private func fetch(seriesID: String, units: String) async throws -> CandleSeries {
        var components = URLComponents(
            string: "https://api.stlouisfed.org/fred/series/observations")!
        components.queryItems = [
            URLQueryItem(name: "series_id",  value: seriesID),
            URLQueryItem(name: "api_key",    value: apiKey),
            URLQueryItem(name: "file_type",  value: "json"),
            // `desc` + `limit` returns the MOST RECENT N observations. With
            // `asc` (the old value) FRED returned the OLDEST N — e.g. PAYEMS
            // gave 1939–1969 instead of the last few years, so every macro card
            // silently showed ancient data. We re-sort to chronological order
            // after decoding (below) so the chart still runs left→right.
            URLQueryItem(name: "sort_order", value: "desc"),
            // Most-recent window for the card sparkline + chart pane. 365 points
            // ≈ 1y of a daily series, ~30y of a monthly one (still recent-anchored).
            URLQueryItem(name: "limit",      value: "365"),
            URLQueryItem(name: "units",      value: units),
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let reply = try JSONDecoder().decode(Reply.self, from: data)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt

        // FRED encodes "no value for this date" as the literal "." —
        // skip those rows entirely instead of synthesising a zero.
        // Fetched newest-first (sort_order=desc); re-sort chronologically so the
        // chart/sparkline read left→right and the "latest" value is candles.last.
        let candles: [Candle] = reply.observations.compactMap { obs -> Candle? in
            guard obs.value != ".",
                  let v = Double(obs.value),
                  let d = df.date(from: obs.date) else { return nil }
            return Candle(time: d, open: v, high: v, low: v, close: v, volume: 0)
        }
        .sorted { $0.time < $1.time }

        return CandleSeries(
            symbol: seriesID,
            interval: .d1,
            candles: candles,
            tz: TimeZone(identifier: "America/New_York") ?? .gmt,
            session: .equityUS
        )
    }

    private struct Reply: Decodable {
        struct Observation: Decodable {
            let date: String
            let value: String
        }
        let observations: [Observation]
    }
}
