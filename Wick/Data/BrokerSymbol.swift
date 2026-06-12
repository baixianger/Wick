import Foundation

/// Normalises **broker-statement ticker formats** into the canonical
/// Yahoo / EastMoney form the data layer can actually fetch.
///
/// Brokerage exports (and the documents Wicker reads via attachments, then
/// records through `portfolio.add`) frequently identify a listing as
/// `SYMBOL:<MIC>` — the ISO-10383 Market Identifier Code — e.g. `BE:XNYS`,
/// `AAPL:XNAS`, `00100:XHKG`, `NOVO-B:XCSE`. Yahoo / EastMoney don't speak MIC:
/// US listings want the bare symbol (`BE`, `AAPL`), non-US want a `.`-delimited
/// Yahoo suffix (`0100.HK`, `NOVO-B.CO`, `7203.T`). Left un-normalised, every
/// such holding fetched empty → the row showed a flat `0.00` with no 涨跌.
///
/// This is a **non-destructive** display/fetch-time pass: the stored holding
/// keeps its original broker string (so re-import / audit stays faithful); only
/// the symbol we *send upstream* is canonicalised. Applied inside
/// `YahooSymbol.map` (so both `LiveDataStore` and `WickMarketDataProvider` get
/// it) and at `LiveDataStore`'s CN-routing fork so HK / A-share MIC forms reach
/// EastMoney.
enum BrokerSymbol {

    /// Convert a possibly-broker-formatted ticker to canonical Yahoo/CN form.
    /// Pass-through for anything without a `:MIC` suffix (already canonical, or
    /// a plain symbol), so it's safe to call unconditionally and idempotently.
    static func canonical(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":") else { return trimmed }
        let code = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        let mic = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty, !mic.isEmpty else { return trimmed }

        // Unknown MIC: leave the original untouched rather than guess — better a
        // visible un-mapped symbol than a silently-wrong fetch.
        guard let suffix = micToYahooSuffix[mic] else { return trimmed }
        // US venues map to the BARE symbol (Yahoo has no US suffix); everything
        // else gets the `.`-delimited Yahoo exchange suffix.
        return suffix.isEmpty ? code : "\(code).\(suffix)"
    }

    /// ISO-10383 MIC → Yahoo exchange suffix. Empty string = US (bare symbol).
    /// Covers the venues retail brokers actually emit; expand as needed.
    static let micToYahooSuffix: [String: String] = [
        // ── United States (→ bare symbol) ──
        "XNAS": "", "XNYS": "", "XASE": "", "ARCX": "", "BATS": "",
        "XNGS": "", "XNCM": "", "XNMS": "", "IEXG": "", "XCIS": "",
        "XPHL": "", "XBOS": "", "EDGX": "", "EDGA": "",
        // ── Greater China ──
        "XHKG": "HK",                 // Hong Kong
        "XSHG": "SS", "XSSC": "SS",   // Shanghai
        "XSHE": "SZ", "XSEC": "SZ",   // Shenzhen
        "XTAI": "TW", "ROCO": "TWO", "XTAD": "TWO",   // Taiwan
        // ── Asia-Pacific ──
        "XTKS": "T", "XJPX": "T",     // Tokyo
        "XKRX": "KS", "XKOS": "KQ",   // Korea (KOSPI / KOSDAQ)
        "XASX": "AX",                 // Australia
        "XNSE": "NS", "XBOM": "BO",   // India (NSE / BSE)
        "XSES": "SI",                 // Singapore
        "XBKK": "BK", "XIDX": "JK",   // Bangkok / Jakarta
        // ── Europe ──
        "XLON": "L",                  // London
        "XETR": "DE", "XFRA": "F",    // Xetra / Frankfurt
        "XPAR": "PA",                 // Paris
        "XAMS": "AS",                 // Amsterdam
        "XBRU": "BR",                 // Brussels
        "XMIL": "MI",                 // Milan
        "XMAD": "MC",                 // Madrid
        "XLIS": "LS",                 // Lisbon
        "XSTO": "ST",                 // Stockholm
        "XHEL": "HE",                 // Helsinki
        "XOSL": "OL",                 // Oslo
        "XCSE": "CO",                 // Copenhagen
        "XWBO": "VI",                 // Vienna
        "XWAR": "WA",                 // Warsaw
        "XSWX": "SW", "XVTX": "SW",   // Switzerland
        // ── Americas ──
        "XTSE": "TO", "XTSX": "V",    // Toronto / TSX-V
        "BVMF": "SA", "XBSP": "SA",   // São Paulo
        "XMEX": "MX",                 // Mexico
        // ── Africa ──
        "XJSE": "JO",                 // Johannesburg
    ]
}
