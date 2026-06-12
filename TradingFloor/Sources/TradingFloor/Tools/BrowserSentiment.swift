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

/// One parsed 雪球 discussion post, reduced to just the fields the news/sentiment
/// analysts care about. Pure Foundation value type so the JSON parser + the
/// news-line formatter below are unit-testable in the package without WebKit —
/// the live WebKit scraper (`BrowserSessionManager` / `XueqiuLiveScraper`) feeds
/// the in-WebKit `fetch(...)` JSON through `XueqiuPostParser` and emits the
/// formatted `newsLine`s into `discussion(for:)`.
public struct XueqiuPost: Sendable, Equatable, Identifiable {
    /// Author screen name (`user.screen_name`); empty when 雪球 omits it.
    public let author: String
    /// Plain-text post body — HTML already stripped + whitespace-collapsed.
    public let text: String
    /// 赞 count (`like_count`, falling back to `fav_count`).
    public let likeCount: Int
    /// 评 count (`reply_count`).
    public let replyCount: Int
    /// Post creation time (`created_at`, 雪球 emits epoch **milliseconds**).
    /// `nil` when 雪球 omits / can't be decoded — the Social card then just
    /// drops the relative-time line rather than guessing.
    public let createdAt: Date?
    /// Permalink to the post on xueqiu.com (`target` / `target_url`,
    /// resolved to an absolute `https://xueqiu.com/…` URL). `nil` when 雪球
    /// omits it — the Social card then renders a non-tappable card.
    public let url: URL?

    /// Stable identity for `ForEach` / `Identifiable`. Composed from the URL
    /// when present (the natural unique key) and otherwise from the content
    /// fields, so two distinct posts never collide and SwiftUI diffing is
    /// stable across refreshes.
    public var id: String {
        url?.absoluteString ?? "\(author)|\(likeCount)|\(replyCount)|\(text)"
    }

    public init(author: String,
                text: String,
                likeCount: Int,
                replyCount: Int,
                createdAt: Date? = nil,
                url: URL? = nil)
    {
        self.author = author
        self.text = text
        self.likeCount = likeCount
        self.replyCount = replyCount
        self.createdAt = createdAt
        self.url = url
    }

    /// Render to the canonical news line, e.g.
    /// `[雪球·张三] 看好后市，估值合理… (赞12 评3)`. The body is HTML-stripped
    /// (already, at parse time) and hard-capped to `textCap` characters so a long
    /// post can't blow up the prompt; an author-less post drops the `·作者` part.
    /// `sourceLabel` defaults to `雪球` (the decorator passes its own).
    public func newsLine(sourceLabel: String = "雪球", textCap: Int = 80) -> String {
        let tag = author.isEmpty ? sourceLabel : "\(sourceLabel)·\(author)"
        let body = Self.truncate(text, to: textCap)
        return "[\(tag)] \(body) (赞\(likeCount) 评\(replyCount))"
    }

    /// Truncate to at most `cap` *characters* (Swift `Character`, so CJK-safe),
    /// appending an ellipsis when clipped. Trailing whitespace is trimmed first.
    static func truncate(_ s: String, to cap: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > cap else { return trimmed }
        return String(trimmed.prefix(cap)) + "…"
    }
}

/// Pure, WebKit-free parser for the 雪球 per-stock posts JSON
/// (`/statuses/search.json?q=<symbol>&sort=time&source=all`, same-origin on
/// `xueqiu.com`). Lives in the package so the JSON→`XueqiuPost` shaping is
/// unit-testable against a captured response without driving real WebKit; the
/// live scraper hands the raw `fetch(...)` body straight through here.
///
/// Tolerant by construction — 雪球 wraps the post array as `list` (the search
/// endpoint) but other timelines use `data.list` / `statuses`; we try each.
/// Per-post text comes from `description` (the rendered HTML body) or `text`,
/// HTML-stripped; counts fall back (`like_count` → `fav_count`). Any malformed
/// entry is skipped rather than failing the whole parse — best-effort, to match
/// `discussion(for:)`'s never-throw contract.
public enum XueqiuPostParser {

    /// Parse a raw JSON body (as returned by the in-WebKit `fetch`) into posts.
    /// Returns `[]` on non-JSON, an `error_code`, or an absent post array.
    public static func parse(_ data: Data) -> [XueqiuPost] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        // A non-zero `error_code` ⇒ 雪球 rejected the request (e.g. logged out).
        if let code = root["error_code"] as? Int, code != 0 { return [] }
        let list = postArray(in: root)
        return list.compactMap(post(from:))
    }

    /// Convenience overload for a decoded JSON string.
    public static func parse(jsonString: String) -> [XueqiuPost] {
        parse(Data(jsonString.utf8))
    }

    /// Locate the post array under the keys 雪球 timelines are known to use.
    private static func postArray(in root: [String: Any]) -> [[String: Any]] {
        if let l = root["list"] as? [[String: Any]] { return l }
        if let l = root["statuses"] as? [[String: Any]] { return l }
        if let data = root["data"] as? [String: Any] {
            if let l = data["list"] as? [[String: Any]] { return l }
            if let l = data["statuses"] as? [[String: Any]] { return l }
        }
        return []
    }

    private static func post(from raw: [String: Any]) -> XueqiuPost? {
        let rawText = (raw["description"] as? String) ?? (raw["text"] as? String) ?? ""
        let text = stripHTML(rawText)
        // Drop posts that reduce to nothing (e.g. pure-image reshares).
        guard !text.isEmpty else { return nil }
        let author = (raw["user"] as? [String: Any])?["screen_name"] as? String ?? ""
        let likes = (raw["like_count"] as? Int) ?? (raw["fav_count"] as? Int) ?? 0
        let replies = (raw["reply_count"] as? Int) ?? 0
        return XueqiuPost(author: author, text: text,
                          likeCount: likes, replyCount: replies,
                          createdAt: createdAt(from: raw),
                          url: permalink(from: raw))
    }

    /// `created_at` is 雪球's epoch **milliseconds** (a large `Int`/`Double`);
    /// convert to a `Date`. `nil` when absent or non-numeric.
    private static func createdAt(from raw: [String: Any]) -> Date? {
        let ms: Double
        if let v = raw["created_at"] as? Double { ms = v }
        else if let v = raw["created_at"] as? Int { ms = Double(v) }
        else { return nil }
        guard ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Resolve the post permalink. 雪球 search posts carry a relative `target`
    /// (e.g. `/1234/567890`); some timelines use `target_url`. Either is
    /// resolved against `https://xueqiu.com`. `nil` when neither is present.
    private static func permalink(from raw: [String: Any]) -> URL? {
        let path = (raw["target_url"] as? String) ?? (raw["target"] as? String)
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: "https://xueqiu.com" + (path.hasPrefix("/") ? path : "/" + path))
    }

    /// Strip HTML tags + decode the handful of entities 雪球 emits, then collapse
    /// runs of whitespace to single spaces. Deliberately small (no full HTML
    /// parse): post bodies are simple `<a>`/`<br>` markup, not documents.
    static func stripHTML(_ html: String) -> String {
        // Replace block/line tags with a space so words don't run together.
        var s = html.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<",
                        "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        // Collapse whitespace (incl. the spaces we just injected) to singles.
        s = s.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One parsed 雪球 NEWS item (the per-stock 资讯/新闻 timeline, distinct from the
/// discussion posts above) reduced to the fields the News tab renders. Pure
/// Foundation value type so the JSON parser is unit-testable without WebKit; the
/// live WebKit scraper feeds the in-WebKit `fetch(...)` JSON through
/// `XueqiuNewsParser` and the app maps these into its own `NewsItem`, badged 雪球
/// alongside the 东方财富 items.
public struct XueqiuNewsItem: Sendable, Equatable, Identifiable {
    /// Headline (`title`, falling back to the post `text`/`description` for the
    /// timeline shape that carries no separate title) — HTML stripped.
    public let title: String
    /// Optional one-line summary/body (`description`/`text`), HTML stripped.
    public let summary: String?
    /// Source/媒体 name (`source`/`user.screen_name`); empty when 雪球 omits it.
    public let source: String
    /// Permalink to the article on xueqiu.com, resolved absolute. `nil` when 雪球
    /// omits it — the News row then renders non-tappable.
    public let url: URL?
    /// Publish time (`created_at`, 雪球 epoch **milliseconds**). `nil` when absent.
    public let createdAt: Date?

    /// Stable identity — the URL when present (the natural key), else the title.
    public var id: String { url?.absoluteString ?? title }

    public init(title: String, summary: String?, source: String,
                url: URL?, createdAt: Date?) {
        self.title = title
        self.summary = summary
        self.source = source
        self.url = url
        self.createdAt = createdAt
    }
}

/// Pure, WebKit-free parser for the 雪球 per-stock NEWS timeline JSON
/// (`/statuses/stock_timeline.json?symbol_id=<symbol>&source=自选股新闻`, same-origin
/// on `xueqiu.com`). Sibling of `XueqiuPostParser` — same tolerant shape
/// (`list`/`statuses`/`data.list`), HTML-stripped via the shared
/// `XueqiuPostParser.stripHTML`. Any malformed entry is skipped (best-effort).
public enum XueqiuNewsParser {

    /// Parse a raw JSON body into news items. `[]` on non-JSON / `error_code` /
    /// an absent list — so the caller degrades to the EastMoney-only News tab.
    public static func parse(_ data: Data) -> [XueqiuNewsItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        if let code = root["error_code"] as? Int, code != 0 { return [] }
        return postArray(in: root).compactMap(item(from:))
    }

    /// Convenience overload for a decoded JSON string.
    public static func parse(jsonString: String) -> [XueqiuNewsItem] {
        parse(Data(jsonString.utf8))
    }

    private static func postArray(in root: [String: Any]) -> [[String: Any]] {
        if let l = root["list"] as? [[String: Any]] { return l }
        if let l = root["statuses"] as? [[String: Any]] { return l }
        if let data = root["data"] as? [String: Any] {
            if let l = data["list"] as? [[String: Any]] { return l }
            if let l = data["statuses"] as? [[String: Any]] { return l }
        }
        return []
    }

    private static func item(from raw: [String: Any]) -> XueqiuNewsItem? {
        // The news timeline carries a `title`; some entries are plain statuses
        // with only `description`/`text` — fall back so we never drop a headline.
        let rawTitle = (raw["title"] as? String) ?? (raw["description"] as? String)
            ?? (raw["text"] as? String) ?? ""
        let title = XueqiuPostParser.stripHTML(rawTitle)
        guard !title.isEmpty else { return nil }
        let rawSummary = (raw["description"] as? String) ?? (raw["text"] as? String) ?? ""
        let summary = XueqiuPostParser.stripHTML(rawSummary)
        // 雪球 news carries `source` (媒体 name); statuses carry `user.screen_name`.
        let source = (raw["source"] as? String)
            ?? ((raw["user"] as? [String: Any])?["screen_name"] as? String) ?? ""
        return XueqiuNewsItem(
            title: title,
            summary: (summary.isEmpty || summary == title) ? nil : summary,
            source: source,
            url: permalink(from: raw),
            createdAt: createdAt(from: raw))
    }

    private static func createdAt(from raw: [String: Any]) -> Date? {
        let ms: Double
        if let v = raw["created_at"] as? Double { ms = v }
        else if let v = raw["created_at"] as? Int { ms = Double(v) }
        else { return nil }
        guard ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static func permalink(from raw: [String: Any]) -> URL? {
        let path = (raw["target_url"] as? String) ?? (raw["target"] as? String)
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: "https://xueqiu.com" + (path.hasPrefix("/") ? path : "/" + path))
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
/// degrade gracefully to a pass-through. The returned strings are the
/// already-formatted `XueqiuPost.newsLine`s (`[雪球·作者] … (赞n 评n)`), built by
/// the live scraper from the in-WebKit `fetch` JSON via `XueqiuPostParser`.
public protocol XueqiuScraping: Sendable {
    /// Current session status (cheap, no network). The decorator reads this to
    /// decide whether to even attempt a scrape.
    var sessionStatus: XueqiuSessionStatus { get async }
    /// Pre-formatted 雪球 discussion news lines for a canonical CN/HK symbol
    /// (`600519.SS`). Best-effort: `[]` on any failure; never throws.
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
    /// Cap appended lines so a chatty discussion page can't blow up the prompt.
    private let maxLines: Int

    public init(base: any MarketDataProvider,
                scraper: any XueqiuScraping,
                enabled: Bool,
                maxLines: Int = 8)
    {
        self.base = base
        self.scraper = scraper
        self.enabled = enabled
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

        // Best-effort scrape — returns [] on any failure, never throws. The
        // lines arrive already formatted + self-tagged (`[雪球·作者] … (赞n 评n)`)
        // by the live scraper's `XueqiuPost.newsLine`, so the decorator only caps
        // + appends; it does not re-wrap with a source label.
        let lines = await scraper.discussion(for: symbol)
        guard !lines.isEmpty else { return snap }

        // Append as news so `brief(for: .sentiment)` / `.news` surface them.
        var out = snap
        out.news.append(contentsOf: lines.prefix(maxLines))
        return out
    }
}
