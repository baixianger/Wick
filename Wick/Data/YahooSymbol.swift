import Foundation

/// Shared Yahoo Finance symbol mapping. Two-faced convention:
///
/// • US class-share separator is `-`, not `.` — `BRK.B` ⇢ `BRK-B`.
/// • Non-US listings carry an exchange suffix delimited by `.` that
///   must be preserved verbatim — `600519.SS` (Shanghai), `0700.HK`
///   (Hong Kong), `7203.T` (Tokyo), `RIO.L` (London), `BMW.DE`
///   (Frankfurt), and so on. Naively replacing every `.` with `-`
///   silently broke every A-share, H-share, and international
///   listing — the request URL came back 404 and downstream
///   consumers got empty data forever.
///
/// Used by `LiveDataStore` (chart/quote streaming) and
/// `WickMarketDataProvider` (TradingFloor agent data) so both
/// surfaces agree on what to send Yahoo.
enum YahooSymbol {

    /// Map a user-entered ticker (e.g. `0700.HK`, `BRK.B`) into the
    /// form Yahoo's chart endpoint expects. Only substitutes `.`
    /// when the trailing token is *not* one of Yahoo's documented
    /// exchange suffixes.
    static func map(_ rawID: String) -> String {
        // First fold any broker `SYMBOL:MIC` form (e.g. `BE:XNYS`,
        // `NOVO-B:XCSE`) into canonical Yahoo/CN form, so imported / agent-
        // recorded holdings resolve instead of 404-ing to a flat row.
        let id = BrokerSymbol.canonical(rawID)
        if let dotIdx = id.lastIndex(of: ".") {
            let suffix = String(id[id.index(after: dotIdx)...]).uppercased()
            if exchangeSuffixes.contains(suffix) { return id }
        }
        return id.replacingOccurrences(of: ".", with: "-")
    }

    /// Yahoo exchange suffixes seen in the wild (subset that matters
    /// most for retail tickers). Expand as needed.
    static let exchangeSuffixes: Set<String> = [
        "SS", "SZ",        // Shanghai / Shenzhen (China A-shares)
        "HK",              // Hong Kong
        "T",               // Tokyo
        "L",               // London
        "TO", "V",         // Toronto, TSX-V
        "PA", "DE", "F",   // Paris, Xetra, Frankfurt
        "AS", "BR", "MI",  // Amsterdam, Brussels, Milan
        "MC", "LS",        // Madrid, Lisbon
        "ST", "HE", "OL",  // Stockholm, Helsinki, Oslo
        "CO",              // Copenhagen
        "VI", "WA", "PR",  // Vienna, Warsaw, Prague
        "BK", "JK",        // Bangkok, Jakarta
        "TW", "TWO",       // Taipei
        "SI",              // Singapore
        "KS", "KQ",        // KOSPI / KOSDAQ
        "AX",              // Sydney
        "NS", "BO",        // NSE / BSE India
        "SA", "MX",        // São Paulo, Mexico
        "JO",              // Johannesburg
    ]
}
