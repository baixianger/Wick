import Testing
import Foundation
@testable import TradingFloor

@Test func cn_symbol_parses_canonical_form() {
    #expect(CNSymbol.parse("600519.SS") == "600519.SS")
    #expect(CNSymbol.parse("000001.SZ") == "000001.SZ")
    #expect(CNSymbol.parse("0700.HK") == "0700.HK")
}

@Test func cn_symbol_normalizes_sh_suffix_to_ss() {
    // EastMoney / akshare convention uses `.SH`; we normalize to Yahoo `.SS`.
    #expect(CNSymbol.parse("600519.SH") == "600519.SS")
    #expect(CNSymbol.parse("000001.sz") == "000001.SZ")
    #expect(CNSymbol.parse("0700.hk") == "0700.HK")
}

@Test func cn_symbol_normalizes_akshare_prefix_form() {
    #expect(CNSymbol.parse("SH600519") == "600519.SS")
    #expect(CNSymbol.parse("SZ000001") == "000001.SZ")
    #expect(CNSymbol.parse("HK00700") == "0700.HK")
    // Prefix-then-dot form some tools emit:
    #expect(CNSymbol.parse("sh.600519") == "600519.SS")
    #expect(CNSymbol.parse("sz.000001") == "000001.SZ")
}

@Test func cn_symbol_infers_market_from_bare_digits() {
    // A-share leading digit decides the market: 6 → Shanghai, 0/3 → Shenzhen.
    #expect(CNSymbol.parse("600519") == "600519.SS")
    #expect(CNSymbol.parse("688981") == "688981.SS")   // 科创板 STAR
    #expect(CNSymbol.parse("000001") == "000001.SZ")
    #expect(CNSymbol.parse("300750") == "300750.SZ")   // 创业板 ChiNext
    // HK pads to 4 digits.
    #expect(CNSymbol.parse("700") == "0700.HK")
    #expect(CNSymbol.parse("00700") == "0700.HK")
    #expect(CNSymbol.parse("9988") == "9988.HK")
}

@Test func cn_symbol_rejects_non_cn_input() {
    #expect(CNSymbol.parse("NVDA") == nil)
    #expect(CNSymbol.parse("BRK.B") == nil)
    #expect(CNSymbol.parse("7203.T") == nil)
    #expect(CNSymbol.parse("茅台") == nil)   // Chinese names go through app-side resolver
    #expect(CNSymbol.parse("") == nil)
    #expect(CNSymbol.parse("  ") == nil)
}

@Test func cn_symbol_market_lookup() {
    #expect(CNSymbol.market("600519.SS") == .shanghai)
    #expect(CNSymbol.market("000001.SZ") == .shenzhen)
    #expect(CNSymbol.market("0700.HK") == .hongKong)
    #expect(CNSymbol.market("NVDA") == nil)
}

@Test func cn_symbol_to_eastmoney_secid() {
    #expect(CNSymbol.eastMoneySecid("600519.SS") == "1.600519")
    #expect(CNSymbol.eastMoneySecid("000001.SZ") == "0.000001")
    // EastMoney expects 5-digit HK codes (canonical Yahoo form is 4 digits).
    #expect(CNSymbol.eastMoneySecid("0700.HK") == "116.00700")
    #expect(CNSymbol.eastMoneySecid("9988.HK") == "116.09988")
    #expect(CNSymbol.eastMoneySecid("NVDA") == nil)
}

@Test func cn_symbol_to_xueqiu_form() {
    // A-shares → SH/SZ-prefixed; HK → bare 5-digit (the form snowball-cli sends
    // to /statuses/search.json and the Social tab's discussion query expects).
    #expect(CNSymbol.xueqiuSymbol("600519.SS") == "SH600519")
    #expect(CNSymbol.xueqiuSymbol("600519.SH") == "SH600519")   // akshare suffix
    #expect(CNSymbol.xueqiuSymbol("000001.SZ") == "SZ000001")
    #expect(CNSymbol.xueqiuSymbol("0700.HK") == "00700")
    #expect(CNSymbol.xueqiuSymbol("9988.HK") == "09988")
    // Non-canonical HK forms a user can enter must all parse-normalize to the
    // same 5-digit query — this is the Social-tab 港股 bug's regression guard.
    #expect(CNSymbol.xueqiuSymbol("00700") == "00700")
    #expect(CNSymbol.xueqiuSymbol("HK0700") == "00700")
    #expect(CNSymbol.xueqiuSymbol("700") == "00700")
    // Non-CN inputs map to nil so the Social tab still shows "unsupported".
    #expect(CNSymbol.xueqiuSymbol("NVDA") == nil)
    #expect(CNSymbol.xueqiuSymbol("BRK.B") == nil)
    #expect(CNSymbol.xueqiuSymbol("7203.T") == nil)
}

@Test func cn_symbol_is_cn_predicate() {
    #expect(CNSymbol.isCN("600519.SS"))
    #expect(CNSymbol.isCN("000001.SZ"))
    #expect(CNSymbol.isCN("0700.HK"))
    #expect(!CNSymbol.isCN("NVDA"))
    #expect(!CNSymbol.isCN("BRK.B"))
    #expect(!CNSymbol.isCN("7203.T"))
}
