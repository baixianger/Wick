import Foundation

/// Per-site browser-session status surfaced by a BYO-cookie scraping source
/// (e.g. 雪球). This is the Mode-2 state machine from
/// `docs/research/webpage-byo-scraping-feasibility.md` §3, hoisted into the
/// Foundation-only package so the gating logic + its unit tests don't need
/// WebKit. The WebKit-bound owner (Wick app's `BrowserSessionManager`) drives
/// the transitions; everything downstream only reads the value.
///
///   • `.unknown`    — not probed yet this session.
///   • `.valid`      — logged-in marker present → scrapes run.
///   • `.expiring`   — session near expiry → scrapes still run, nudge re-login.
///   • `.expired`    — login wall detected / cookie gone → source auto-pauses.
///   • `.needsLogin` — never connected → user must sign in once.
public enum XueqiuSessionStatus: String, Sendable, Equatable, Codable {
    case unknown
    case valid
    case expiring
    case expired
    case needsLogin

    /// Only `.valid` / `.expiring` may scrape — the "never scrape with a stale
    /// session" guarantee (§3 Mode 2). `.unknown` / `.expired` / `.needsLogin`
    /// all pause the source.
    public var canScrape: Bool {
        switch self {
        case .valid, .expiring: return true
        case .unknown, .expired, .needsLogin: return false
        }
    }
}

/// Foundation-only seam over the app-side browser scraper. The Wick app target
/// supplies the live, WebKit-backed implementation (`BrowserSessionManager`);
/// tests supply a deterministic mock. Keeping the seam in the package lets the
/// gating/decorator logic be unit-tested without WebKit and keeps the package
/// Linux-clean (no WebKit import).
///
/// `discussion(for:)` is **best-effort**: it returns `[]` on no-session /
/// expired / empty / timeout and **never throws**, so the decorator below can
/// degrade gracefully to a pass-through.
public protocol XueqiuScraping: Sendable {
    /// Current session status (cheap, no network). The decorator reads this to
    /// decide whether to even attempt a scrape.
    var sessionStatus: XueqiuSessionStatus { get async }
    /// Headless discussion lines for a canonical CN/HK symbol (`600519.SS`).
    /// Best-effort: `[]` on any failure; never throws.
    func discussion(for symbol: String) async -> [String]
}

/// Decorator that appends BYO-cookie 雪球 discussion lines into a snapshot's
/// `news` for CN/HK tickers, so the sentiment/news analysts see them. Lives in
/// the package (not the app) only because it is pure Foundation gating logic
/// over the `XueqiuScraping` seam — the WebKit work happens inside the injected
/// scraper. The app assembles this into the chain at `buildMarketData`.
///
/// **Off by default + best-effort + view-independent:**
///   • `enabled` gates the whole decorator (driven by `AgentSettings`,
///     default FALSE). Disabled → pure pass-through, scraper never touched.
///   • Non-CN/HK tickers → pass-through (gated via `CNSymbol`).
///   • Session not scrapable (`.unknown`/`.expired`/`.needsLogin`) → pass-through.
///   • Empty scrape / any failure → pass-through, snapshot unchanged.
/// In all of those cases the base snapshot flows through untouched, so this can
/// never break the existing chain or any non-CN run.
public struct BYODiscussionNewsDecorator: MarketDataProvider {
    private let base: any MarketDataProvider
    private let scraper: any XueqiuScraping
    private let enabled: Bool
    private let sourceLabel: String
    /// Cap appended lines so a chatty discussion page can't blow up the prompt.
    private let maxLines: Int

    public init(base: any MarketDataProvider,
                scraper: any XueqiuScraping,
                enabled: Bool,
                sourceLabel: String = "雪球",
                maxLines: Int = 8)
    {
        self.base = base
        self.scraper = scraper
        self.enabled = enabled
        self.sourceLabel = sourceLabel
        self.maxLines = maxLines
    }

    public func snapshot(symbol: String, asOf: Date) async throws -> MarketSnapshot {
        let snap = try await base.snapshot(symbol: symbol, asOf: asOf)

        // Gate 1: off by default — disabled means we never touch the scraper.
        guard enabled else { return snap }
        // Gate 2: CN/HK only.
        guard CNSymbol.isCN(symbol) else { return snap }
        // Gate 3: never scrape with a stale/absent session.
        guard await scraper.sessionStatus.canScrape else { return snap }

        // Best-effort scrape — returns [] on any failure, never throws.
        let lines = await scraper.discussion(for: symbol)
        guard !lines.isEmpty else { return snap }

        // Append as news so `brief(for: .sentiment)` / `.news` surface them.
        var out = snap
        let tagged = lines
            .prefix(maxLines)
            .map { "[\(sourceLabel)] \($0)" }
        out.news.append(contentsOf: tagged)
        return out
    }
}
