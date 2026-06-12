import Foundation
import Observation
import TradingFloor
import os

/// GUI-side responder for the cross-process `SharedBridge`. When ACTIVE, it
/// polls the App-Group `Bridge/requests/` directory on a timer, executes each
/// request against the LIVE in-process capabilities — the `@MainActor`
/// `BrowserSessionManager` (navigate / read / snapshot) and the 雪球 / X
/// discussion scrapers — and writes a `BridgeResponse` the sandboxed `wick-mcp`
/// helper picks up.
///
/// # Why this exists
/// `wick-mcp` is a separate sandboxed subprocess; it can reach the App-Group
/// container but not WebKit or the GUI's memory. So the new MCP tools
/// (`wick.web_navigate` / `web_read` / `web_snapshot` / `xueqiu_discussion` /
/// `x_discussion`) can't run in the helper — they're serviced HERE, in the GUI,
/// against the user's already-logged-in browser/social sessions, and the result
/// is shuttled back through the file bridge.
///
/// # Activation gating (security)
/// The server polls + answers ONLY when ALL of:
///   1. `exposeWickerViaMCP` is on (NEW opt-in flag, default FALSE),
///   2. we're on macOS 26 (the `WebPage` / `BrowserSessionManager` API floor),
///   3. `enableWickerBrowser` is on (the browser feature itself is enabled).
/// When any is false the timer is torn down and NO requests are serviced — the
/// helper's calls simply time out and it tells the user to enable the feature.
///
/// All exposed ops are READ-only (navigate/read/snapshot + discussion reads); no
/// page-mutating click/type/eval is reachable over the bridge. So
/// `allowWickerBrowserWrites` doesn't need to be consulted here — there's nothing
/// to write. (If a mutating op were ever added it would additionally honor that
/// flag.)
@available(macOS 26.0, *)
@MainActor
@Observable
final class BridgeServer {

    @ObservationIgnored private let manager: BrowserSessionManager
    @ObservationIgnored private let log = Logger(subsystem: "me.impai.wick", category: "BridgeServer")

    /// The poll timer. `nil` when inactive. Re-created by `start()`, invalidated
    /// by `stop()`. ~0.4s cadence keeps round-trip latency low while staying far
    /// below the helper's ~20s wait budget.
    @ObservationIgnored private var timer: Timer?

    /// In-flight request ids, so a slow execution (a navigation can take
    /// seconds) doesn't get re-dispatched by the next tick. `pollRequests()`
    /// already deletes the request file on read, but a request whose execution
    /// is still running shouldn't block the tick — we just guard against double
    /// servicing the SAME id within one process.
    @ObservationIgnored private var inFlight: Set<UUID> = []

    /// Whether the server is currently polling. Observable so a status row could
    /// surface it later; harmless if unused.
    private(set) var isActive = false

    init(manager: BrowserSessionManager) {
        self.manager = manager
    }

    // MARK: - Lifecycle

    /// Begin polling the bridge. Idempotent — a second call while already active
    /// is a no-op. Called by the host when the activation gate flips ON.
    func start() {
        guard !isActive else { return }
        guard SharedBridge.isAvailable else {
            log.info("[BridgeServer] App-Group container unavailable — not starting")
            return
        }
        log.info("[BridgeServer] starting — servicing MCP browser/social requests")
        isActive = true
        // Drain any requests that piled up before we started (e.g. helper called
        // while the gate was briefly off), then schedule the recurring poll.
        let t = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop; hop onto the MainActor explicitly
            // for Swift-concurrency isolation.
            Task { @MainActor [weak self] in self?.tick() }
        }
        // Common-mode so polling continues during menu tracking / scrolling.
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    /// Stop polling and tear down the timer. Idempotent. Called when the gate
    /// flips OFF (flag toggled, etc.). Any already-written responses remain for
    /// the helper to pick up; new requests are no longer serviced.
    func stop() {
        guard isActive else { return }
        log.info("[BridgeServer] stopping — no longer servicing MCP requests")
        timer?.invalidate()
        timer = nil
        isActive = false
    }

    /// Re-evaluate the activation gate from settings and start/stop accordingly.
    /// Host calls this on launch + on every relevant flag change.
    func reconfigure(with settings: AgentSettings) {
        let shouldRun = settings.exposeWickerViaMCP && settings.enableWickerBrowser
        if shouldRun { start() } else { stop() }
    }

    // MARK: - Poll + dispatch

    /// One poll cycle: read pending requests, execute each, write its response.
    private func tick() {
        let requests = SharedBridge.pollRequests()
        guard !requests.isEmpty else { return }
        for req in requests where !inFlight.contains(req.id) {
            inFlight.insert(req.id)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let resp = await self.execute(req)
                SharedBridge.writeResponse(resp)
                self.inFlight.remove(req.id)
            }
        }
    }

    /// Execute one request against the live capabilities and render a response.
    /// Always returns a `BridgeResponse` — every path is best-effort and never
    /// throws, so the helper always gets an answer (even if it's an error text).
    private func execute(_ req: BridgeRequest) async -> BridgeResponse {
        guard let tool = req.toolKind else {
            return fail(req, "未知的 bridge 工具：\(req.tool)")
        }
        switch tool {
        case .webNavigate:
            guard let url = req.string("url"), !url.isEmpty else {
                return fail(req, "`url` 不能为空")
            }
            let text = await manager.navigate(to: url)
            return ok(req, text)

        case .webRead:
            // `selector` optional — nil reads the whole page body.
            let selector = req.string("selector")
            let text = await manager.readText(selector: selector?.isEmpty == true ? nil : selector)
            return ok(req, text)

        case .webSnapshot:
            let full = req.bool("full") ?? false
            let viewportOnly = req.bool("viewportOnly") ?? false
            let text = await manager.snapshotOutline(full: full, viewportOnly: viewportOnly, verbose: false)
            return ok(req, text)

        case .xueqiuDiscussion:
            guard let symbol = req.string("symbol"), !symbol.isEmpty else {
                return fail(req, "`symbol` 不能为空")
            }
            let posts = await manager.posts(for: symbol)
            return ok(req, Self.renderXueqiu(symbol: symbol, posts: posts))

        case .xDiscussion:
            guard let symbol = req.string("symbol"), !symbol.isEmpty else {
                return fail(req, "`symbol` 不能为空")
            }
            let posts = await manager.xPosts(for: symbol)
            return ok(req, Self.renderX(symbol: symbol, posts: posts))
        }
    }

    // MARK: - Rendering

    private static func renderXueqiu(symbol: String, posts: [XueqiuPost]) -> String {
        guard !posts.isEmpty else {
            return "雪球：未找到 \(symbol) 的讨论(可能未登录雪球、该标的非 A 股/港股,或当前无帖)。"
                + "\n如需此源,请在 Wick 个股页 Social 标签登录雪球,并确认 \(symbol) 为 A 股/港股标的。"
        }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        var lines = ["# 雪球讨论 — \(symbol) (\(posts.count) 条)", ""]
        for p in posts.prefix(30) {
            let time = p.createdAt.map { " · \(df.string(from: $0))" } ?? ""
            let author = p.author.isEmpty ? "匿名" : p.author
            lines.append("**\(author)**\(time) — 赞\(p.likeCount) 评\(p.replyCount)")
            lines.append(p.text)
            if let url = p.url { lines.append(url.absoluteString) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderX(symbol: String, posts: [XPost]) -> String {
        let cashtag = BrowserSessionManager.cashtag(for: symbol)
        guard !posts.isEmpty else {
            return "X：未找到 \(cashtag) 的讨论(可能未登录 X,或该 cashtag 当前无近期推文)。"
                + "\n如需此源,请在 Wick 个股页 Social 标签登录 X。"
        }
        var lines = ["# X 讨论 — \(cashtag) (\(posts.count) 条)", ""]
        for p in posts.prefix(30) {
            let handle = p.handle.isEmpty ? "(unknown)" : p.handle
            lines.append("**\(handle)**")
            lines.append(p.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Result helpers

    private func ok(_ req: BridgeRequest, _ text: String) -> BridgeResponse {
        BridgeResponse(id: req.id, ok: true, text: text)
    }

    private func fail(_ req: BridgeRequest, _ text: String) -> BridgeResponse {
        BridgeResponse(id: req.id, ok: false, text: text)
    }
}
