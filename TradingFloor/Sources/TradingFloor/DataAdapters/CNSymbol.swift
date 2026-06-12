import Foundation

/// Symbol parsing + market routing helpers for Chinese A-shares (Shanghai /
/// Shenzhen) and Hong Kong stocks. Canonical form throughout the codebase is
/// the Yahoo-style suffix:
///
///   • A-shares Shanghai:  `600519.SS`
///   • A-shares Shenzhen:  `000001.SZ`
///   • Hong Kong:          `0700.HK`
///
/// This matches the `YahooSymbol.exchangeSuffixes` set the app already uses
/// for charts, so the same string flows through TradingFloor, CandleKit's
/// `YahooFinanceAdapter`, and persistent stores (Holdings, Watchlist) without
/// translation. EastMoney's `secid` format (`1.600519`, `0.000001`, `116.00700`)
/// is computed at the network boundary, not stored.
public enum CNSymbol {

    public enum Market: String, Sendable {
        case shanghai = "SS"
        case shenzhen = "SZ"
        case hongKong = "HK"
    }

    /// Normalize a user-entered string into canonical form. Returns `nil` for
    /// non-CN inputs (plain US tickers, other international suffixes, or pure
    /// non-numeric Chinese names — those are resolved by the app-side
    /// `ChineseSymbolResolver`, not here). This stays Foundation-only so it
    /// works in WickServer too.
    ///
    /// Accepted shapes (all → canonical):
    ///   `600519.SS` / `600519.SH` / `SH600519` / `sh.600519` / `600519`
    ///   `000001.SZ` / `SZ000001` / `000001`
    ///   `0700.HK`   / `HK0700`   / `HK.0700`  / `00700` / `700`
    public static func parse(_ input: String) -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !raw.isEmpty else { return nil }

        // Already-suffixed form: split on last '.' and normalize the suffix.
        if let dot = raw.lastIndex(of: ".") {
            let code = String(raw[..<dot])
            let suffixRaw = String(raw[raw.index(after: dot)...])
            // East-Money / akshare sometimes uses `SH` instead of Yahoo's `SS`.
            let suffix = (suffixRaw == "SH") ? "SS" : suffixRaw
            // Also handle `SH.600519` shape (prefix before dot).
            if Market(rawValue: suffix) != nil, let normalized = normalize(code: code, market: Market(rawValue: suffix)!) {
                return normalized
            }
            // Prefix-style with a dot: `SH.600519` / `SZ.000001` / `HK.0700`.
            if let prefixMarket = prefixMarket(code) {
                return normalize(code: suffixRaw, market: prefixMarket)
            }
        }

        // Prefix-style without a dot: `SH600519` / `SZ000001` / `HK0700`.
        if let prefixMarket = prefixMarket(raw) {
            let body = String(raw.dropFirst(2))
            return normalize(code: body, market: prefixMarket)
        }

        // Bare digits — infer market from the code itself.
        if raw.allSatisfy(\.isNumber) {
            return inferMarketFromDigits(raw)
        }

        return nil
    }

    /// Canonical → `Market`. `600519.SS` → `.shanghai`.
    public static func market(_ canonical: String) -> Market? {
        guard let dot = canonical.lastIndex(of: ".") else { return nil }
        let suffix = String(canonical[canonical.index(after: dot)...]).uppercased()
        return Market(rawValue: suffix)
    }

    /// Canonical → EastMoney `secid` format. `600519.SS` → `"1.600519"`,
    /// `000001.SZ` → `"0.000001"`, `0700.HK` → `"116.00700"` (HK is
    /// zero-padded to 5 digits for the EastMoney endpoint, even though the
    /// canonical Yahoo form is 4 digits).
    public static func eastMoneySecid(_ canonical: String) -> String? {
        guard let market = market(canonical) else { return nil }
        let code = canonical.split(separator: ".").first.map(String.init) ?? ""
        guard !code.isEmpty else { return nil }
        switch market {
        case .shanghai: return "1.\(code)"
        case .shenzhen: return "0.\(code)"
        case .hongKong: return "116.\(hkSecidCode(code))"
        }
    }

    /// Canonical → EastMoney F10 `SECUCODE` filter. Used by HK F10 endpoints
    /// (`RPT_HKF10_*`) that expect the 5-digit HK form regardless of how
    /// many digits the canonical 4-digit code carries. A-shares already
    /// match what F10 wants (`SECUCODE` = `600519.SH` style for some
    /// tables, `600519.SS` for others — currently only HK uses this helper).
    public static func eastMoneyF10HKSecucode(_ canonical: String) -> String? {
        guard market(canonical) == .hongKong else { return nil }
        let code = canonical.split(separator: ".").first.map(String.init) ?? ""
        guard !code.isEmpty else { return nil }
        return "\(hkSecidCode(code)).HK"
    }

    /// Canonical → EastMoney datacenter `SECUCODE` filter (`CODE.SH` / `CODE.SZ`
    /// / `CODE.HK`). The `datacenter-web` F10 tables key on this dotted-suffix
    /// form — note `SH`/`SZ` (NOT Yahoo's `SS`) and the 5-digit HK code. Used by
    /// the F10 financial-indicator table (`RPT_F10_FINANCE_MAINFINADATA`), which
    /// filters on `(SECUCODE="600519.SH")`. Returns `nil` for non-CN inputs.
    public static func eastMoneyF10Secucode(_ input: String) -> String? {
        let canonical = market(input) != nil ? input : (parse(input) ?? input)
        guard let market = market(canonical) else { return nil }
        let code = canonical.split(separator: ".").first.map(String.init) ?? ""
        guard !code.isEmpty else { return nil }
        switch market {
        case .shanghai: return "\(code).SH"
        case .shenzhen: return "\(code).SZ"
        case .hongKong: return "\(hkSecidCode(code)).HK"
        }
    }

    /// Any CN/HK symbol form → 雪球 (Xueqiu) symbol form, the prefix/path shape
    /// 雪球's web API + stock pages use:
    ///   • Shanghai `600519.SS` → `SH600519`
    ///   • Shenzhen `000001.SZ` → `SZ000001`
    ///   • Hong Kong `0700.HK`  → `00700` (bare 5-digit, e.g. `/S/00700`)
    /// The input is parse-normalized first, so non-canonical forms the user can
    /// enter (`HK0700`, `00700`, `700`, `600519.SH`) all map correctly — not just
    /// the canonical `*.SS/.SZ/.HK` string. Centralised here (Foundation-only,
    /// unit-tested) so every call site (the Social tab gate, the WebKit scraper,
    /// the sentiment decorator) gets the same forgiving mapping. Returns `nil`
    /// for non-CN inputs.
    ///
    /// The 5-digit HK form matches what snowball-cli sends to the same
    /// `/statuses/search.json?q=` endpoint (it detects HK by `/^\d{5}$/`), so
    /// `0700.HK → 00700` is the query 雪球 expects for HK discussion.
    public static func xueqiuSymbol(_ input: String) -> String? {
        // Accept any user-entered form by normalizing to canonical first; the
        // canonical fast-path (`market != nil`) still short-circuits unchanged.
        let canonical = market(input) != nil ? input : (parse(input) ?? input)
        guard let market = market(canonical) else { return nil }
        let code = canonical.split(separator: ".").first.map(String.init) ?? ""
        guard !code.isEmpty else { return nil }
        switch market {
        case .shanghai: return "SH\(code)"
        case .shenzhen: return "SZ\(code)"
        case .hongKong: return hkSecidCode(code)   // 雪球 HK uses the 5-digit form
        }
    }

    /// Convenience: is this canonical string a CN/HK symbol?
    public static func isCN(_ canonical: String) -> Bool {
        market(canonical) != nil
    }

    // MARK: - Private

    private static func prefixMarket(_ raw: String) -> Market? {
        guard raw.count >= 2 else { return nil }
        let prefix = String(raw.prefix(2))
        switch prefix {
        case "SH", "SS": return .shanghai
        case "SZ":       return .shenzhen
        case "HK":       return .hongKong
        default:         return nil
        }
    }

    private static func normalize(code: String, market: Market) -> String? {
        let digits = code.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        switch market {
        case .shanghai, .shenzhen:
            // A-share codes are exactly 6 digits.
            guard digits.count == 6 else { return nil }
            return "\(digits).\(market.rawValue)"
        case .hongKong:
            return "\(hkCanonicalCode(digits)).HK"
        }
    }

    /// Hong Kong code → Yahoo-style 4-digit canonical. Leading zeros are
    /// stripped, then the result is left-padded to exactly 4 digits.
    /// 5+ digit codes (warrants / derivatives) past leading zeros are kept
    /// at their natural width: `99988` → `99988`, `00700` → `0700`.
    private static func hkCanonicalCode(_ digits: String) -> String {
        let trimmed = digits.drop(while: { $0 == "0" })
        let core = trimmed.isEmpty ? "0" : String(trimmed)
        if core.count >= 4 { return core }
        return String(repeating: "0", count: 4 - core.count) + core
    }

    /// Hong Kong code → EastMoney 5-digit secid form. EastMoney's `push2`
    /// endpoints expect Tencent as `116.00700`, not `116.0700`.
    private static func hkSecidCode(_ canonical: String) -> String {
        let trimmed = canonical.drop(while: { $0 == "0" })
        let core = trimmed.isEmpty ? "0" : String(trimmed)
        if core.count >= 5 { return core }
        return String(repeating: "0", count: 5 - core.count) + core
    }

    /// Decide A-share market from the bare code's leading digit. Bare 5+ digit
    /// codes that fit HK's range (≤ 5) fall through to HK.
    private static func inferMarketFromDigits(_ digits: String) -> String? {
        guard !digits.isEmpty else { return nil }

        // HK heuristic: 1-5 digits → Hong Kong (no A-share is < 6 digits).
        if digits.count < 6 {
            return normalize(code: digits, market: .hongKong)
        }
        // 6-digit codes → A-share, infer by prefix.
        if digits.count == 6, let first = digits.first {
            switch first {
            case "6", "9":              // 6xx = main board Shanghai; 9xx = B-shares Shanghai
                return "\(digits).SS"
            case "0", "2", "3":         // 0xx/3xx = main/ChiNext Shenzhen; 2xx = B-shares Shenzhen
                return "\(digits).SZ"
            default:
                return nil
            }
        }
        // 7+ digits → not a valid CN ticker.
        return nil
    }
}
