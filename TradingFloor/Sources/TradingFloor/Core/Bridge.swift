import Foundation

/// Live cross-process request/response bridge between the sandboxed
/// `wick-mcp` helper and the GUI app, layered on the SAME App-Group
/// container `SharedStore` already owns (`group.me.impai.wick`).
///
/// # Why a file bridge
/// The browser-operation capabilities (navigate / read / snapshot) and
/// the 雪球 / X discussion scrapers live INSIDE the GUI process — they're
/// `@MainActor`, WebKit-backed, and hold the user's logged-in cookie jars.
/// `wick-mcp` is a separate, sandboxed stdio subprocess that can reach the
/// App-Group container but NOT arbitrary FS / WebKit / the GUI's memory.
/// So the helper can't call those APIs directly. Instead it drops a
/// **request file** into the shared container and polls for a **response
/// file** the GUI writes back. This is the only sanctioned IPC channel
/// (same container the reports / holdings already flow through), so it
/// doesn't widen the helper's sandbox one bit.
///
/// # Container layout
/// ```
/// <App-Group container>/Bridge/
///   requests/<uuid>.json     ← helper writes, GUI consumes + deletes
///   responses/<uuid>.json    ← GUI writes, helper consumes + deletes
/// ```
/// Each filename is the request `id` (a UUID) so a response is trivially
/// matched to its request. Both directions are bounded (payload caps) and
/// TTL-swept (stale files older than `ttl` are dropped) so a flood of
/// orphaned files — e.g. the GUI never came up to answer — can't grow the
/// container without limit.
///
/// # Security
/// The GUI services requests ONLY when the user has explicitly opted in
/// (`exposeWickerViaMCP`, default FALSE) AND the browser feature is on AND
/// we're on macOS 26. When inactive, NOTHING here is polled or answered —
/// the helper's calls simply time out and return a clear "not enabled"
/// message. Foundation-only so it stays Linux-clean inside the package.
public enum SharedBridge {

    /// Max bytes we'll read for any single request/response file. A larger
    /// file is treated as corrupt and skipped — the helper's args and the
    /// GUI's text result are both small (a URL, a selector, a few KB of
    /// page text), so this is a generous ceiling that still caps a flood.
    public static let maxPayloadBytes = 256 * 1024

    /// Files older than this are swept on each poll. The helper waits up to
    /// ~20s for a response; 60s gives comfortable headroom while still
    /// bounding orphaned files from a GUI that never answered.
    public static let ttl: TimeInterval = 60

    /// Tools the helper is allowed to ask the GUI to run, mirrored on both
    /// sides. The GUI rejects anything not in this set; the helper only
    /// enqueues these. Keeping it here (shared package) means one source of
    /// truth for the allowed surface.
    public enum Tool: String, Sendable, CaseIterable {
        case webNavigate       = "web_navigate"
        case webRead           = "web_read"
        case webSnapshot       = "web_snapshot"
        case xueqiuDiscussion  = "xueqiu_discussion"
        case xDiscussion       = "x_discussion"
    }

    // MARK: - Directories

    /// `<container>/Bridge`. Returns nil when the App-Group container isn't
    /// reachable (unsigned dev build) — callers then treat the bridge as
    /// simply unavailable.
    public static var bridgeDirectoryURL: URL? {
        let fm = FileManager.default
        guard let container = fm.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.appGroupID) else {
            return nil
        }
        let dir = container.appendingPathComponent("Bridge", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var requestsDirectoryURL: URL? {
        guard let base = bridgeDirectoryURL else { return nil }
        let dir = base.appendingPathComponent("requests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var responsesDirectoryURL: URL? {
        guard let base = bridgeDirectoryURL else { return nil }
        let dir = base.appendingPathComponent("responses", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// True when the on-disk App-Group container is actually present, i.e.
    /// the bridge has somewhere to live. (Distinct from `SharedStore`'s
    /// UserDefaults probe — here we care about the file container.)
    public static var isAvailable: Bool {
        bridgeDirectoryURL != nil
    }

    // MARK: - Helper side: enqueue a request, await a response

    /// Drop a request file into `requests/`. Returns false if the container
    /// isn't reachable or the payload is over-size (so the caller can fail
    /// fast with a clear message instead of hanging).
    @discardableResult
    public static func enqueueRequest(_ request: BridgeRequest) -> Bool {
        guard let dir = requestsDirectoryURL else { return false }
        guard let data = try? encoder.encode(request),
              data.count <= maxPayloadBytes else { return false }
        let url = dir.appendingPathComponent("\(request.id.uuidString).json")
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Read the response for `id` if the GUI has written one, else nil. The
    /// helper polls this. Consuming a response deletes it so the directory
    /// stays small.
    public static func readResponse(id: UUID) -> BridgeResponse? {
        guard let dir = responsesDirectoryURL else { return nil }
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              data.count <= maxPayloadBytes,
              let resp = try? decoder.decode(BridgeResponse.self, from: data)
        else { return nil }
        try? FileManager.default.removeItem(at: url)   // one-shot consume
        return resp
    }

    /// Discard a request the helper gave up waiting on, so the GUI doesn't
    /// later answer a request nobody is listening for. Best-effort.
    public static func cancelRequest(id: UUID) {
        guard let dir = requestsDirectoryURL else { return }
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent("\(id.uuidString).json"))
    }

    // MARK: - GUI side: poll requests, write responses

    /// Read every pending request in `requests/`, newest-first, dropping +
    /// deleting any that are stale (older than `ttl`) or unparseable. The
    /// GUI's `BridgeServer` calls this on a timer, executes each, and writes
    /// a response. Consuming a request file here deletes it so it's serviced
    /// exactly once.
    public static func pollRequests() -> [BridgeRequest] {
        guard let dir = requestsDirectoryURL else { return [] }
        sweepStale(in: dir)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [BridgeRequest] = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  data.count <= maxPayloadBytes,
                  let req = try? decoder.decode(BridgeRequest.self, from: data)
            else {
                // Unparseable / oversize → remove so it isn't re-read forever.
                try? fm.removeItem(at: url)
                continue
            }
            // Consume the request file immediately so a slow execution doesn't
            // let a second poll pick up the same request.
            try? fm.removeItem(at: url)
            out.append(req)
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    /// Write a response file the helper will pick up. Best-effort; over-size
    /// payloads are truncated to keep the container bounded.
    public static func writeResponse(_ response: BridgeResponse) {
        guard let dir = responsesDirectoryURL else { return }
        var resp = response
        // Bound the text so one giant page read can't blow the cap.
        if let data = resp.text.data(using: .utf8), data.count > maxPayloadBytes {
            let capped = String(decoding: data.prefix(maxPayloadBytes - 256), as: UTF8.self)
            resp = BridgeResponse(id: resp.id, ok: resp.ok,
                                  text: capped + "\n…(truncated)", finishedAt: resp.finishedAt)
        }
        guard let data = try? encoder.encode(resp) else { return }
        let url = dir.appendingPathComponent("\(resp.id.uuidString).json")
        try? data.write(to: url, options: .atomic)
        // Opportunistically sweep stale responses too.
        sweepStale(in: dir)
    }

    // MARK: - TTL sweep

    /// Delete files in `dir` whose modification time is older than `ttl`.
    private static func sweepStale(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-ttl)
        for url in entries {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let mod, mod < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Codec

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Wire types

/// One request from the helper to the GUI. `tool` is the raw value of a
/// `SharedBridge.Tool`; `args` is a small, JSON-only argument bag.
public struct BridgeRequest: Codable, Sendable {
    public var id: UUID
    public var tool: String
    public var args: [String: JSONValue]
    public var createdAt: Date

    public init(id: UUID = UUID(),
                tool: String,
                args: [String: JSONValue],
                createdAt: Date = Date())
    {
        self.id = id
        self.tool = tool
        self.args = args
        self.createdAt = createdAt
    }

    /// Typed accessor for the tool, nil for an unknown name (which the GUI
    /// rejects).
    public var toolKind: SharedBridge.Tool? { SharedBridge.Tool(rawValue: tool) }

    /// Convenience string getter for an arg.
    public func string(_ key: String) -> String? {
        if case .string(let s)? = args[key] { return s }
        return nil
    }

    /// Convenience bool getter for an arg (also accepts numeric 0/1).
    public func bool(_ key: String) -> Bool? {
        switch args[key] {
        case .bool(let b)?:   return b
        case .number(let n)?: return n != 0
        default:              return nil
        }
    }
}

/// One response from the GUI back to the helper. `text` is the rendered
/// result the MCP tool surfaces verbatim to the calling LLM.
public struct BridgeResponse: Codable, Sendable {
    public var id: UUID
    public var ok: Bool
    public var text: String
    public var finishedAt: Date

    public init(id: UUID, ok: Bool, text: String, finishedAt: Date = Date()) {
        self.id = id
        self.ok = ok
        self.text = text
        self.finishedAt = finishedAt
    }
}

/// Minimal JSON value enum so the bridge's `args` are strongly-typed,
/// Codable, and Sendable without dragging `[String: Any]` (non-Sendable)
/// across the process boundary. Covers exactly the shapes the bridge tools
/// need — strings, bools, numbers, plus null for completeness.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported JSONValue")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b):   try c.encode(b)
        case .null:          try c.encodeNil()
        }
    }
}
