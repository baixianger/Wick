import Foundation
import Observation

/// One message in a chat session. Role mirrors `LLMMessage.Role` plus a
/// `system` case (not sent through the provider — used for inline
/// notices like "switched to local model" or transient errors).
struct ChatMessage: Identifiable, Codable, Equatable, Hashable {
    enum Role: String, Codable { case user, assistant, system }

    let id: UUID
    let role: Role
    var text: String
    let createdAt: Date
    /// Files the user attached to this turn (images Wicker sees via vision,
    /// documents folded into the prompt as extracted text). Empty for every
    /// assistant/system message and for plain text-only user turns. Decoded
    /// with `decodeIfPresent` so sessions persisted before attachments existed
    /// still load (the key is simply absent → `[]`).
    var attachments: [ChatAttachment]

    init(id: UUID = UUID(),
         role: Role,
         text: String,
         createdAt: Date = .now,
         attachments: [ChatAttachment] = [])
    {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, createdAt, attachments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.role = try c.decode(Role.self, forKey: .role)
        self.text = try c.decode(String.self, forKey: .text)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.attachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
    }
}

/// A single conversation. `pinnedSymbol` is an optional context anchor —
/// when the user starts a chat from a ticker page in the future, we'll
/// stamp the symbol here so the agent knows what's on screen.
struct ChatSession: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date
    var pinnedSymbol: String?

    init(id: UUID = UUID(),
         title: String = "New chat",
         messages: [ChatMessage] = [],
         createdAt: Date = .now,
         updatedAt: Date = .now,
         pinnedSymbol: String? = nil)
    {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pinnedSymbol = pinnedSymbol
    }
}

/// Sessions + persistence for the global Assistant. JSON file in the
/// app's Application Support container; written on every mutation. The
/// store is small (text only) so eager full-file rewrites are fine —
/// no incremental save machinery needed.
@MainActor
@Observable
final class ChatStore {

    private(set) var sessions: [ChatSession]
    var selectedSessionID: UUID?
    private var sessionStates: [UUID: ChatSessionState]
    @ObservationIgnored private let storageURL: URL

    init(storageURL: URL? = nil) {
        let url = storageURL ?? Self.storeURL
        self.storageURL = url
        let loaded = Self.loadFromDisk(at: url)
        self.sessions = loaded
        self.sessionStates = Dictionary(loaded.map { ($0.id, ChatSessionState()) },
                                        uniquingKeysWith: { first, _ in first })
        self.selectedSessionID = loaded.first?.id
    }

    func state(for sessionID: UUID) -> ChatSessionState? {
        sessionStates[sessionID]
    }

    // MARK: - Mutations

    /// Create an empty session, prepend it (most-recent first), select
    /// it, and persist. Returns the new session id.
    @discardableResult
    func newSession(pinnedSymbol: String? = nil) -> UUID {
        let s = ChatSession(pinnedSymbol: pinnedSymbol)
        sessionStates[s.id] = ChatSessionState()
        sessions.insert(s, at: 0)
        selectedSessionID = s.id
        persist()
        return s.id
    }

    func delete(id: UUID) {
        sessionStates.removeValue(forKey: id)?.invalidate()
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id { selectedSessionID = sessions.first?.id }
        persist()
    }

    func rename(id: UUID, to title: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].title = title
        sessions[i].updatedAt = .now
        persist()
    }

    func append(_ message: ChatMessage, to sessionID: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[i].messages.append(message)
        sessions[i].updatedAt = .now
        // First user turn — auto-title from its first line so the rail
        // shows something more useful than "New chat".
        if sessions[i].title == "New chat",
           message.role == .user,
           let firstLine = message.text.split(whereSeparator: \.isNewline).first
        {
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            sessions[i].title = String(trimmed.prefix(40))
        }
        // Bubble newest-touched session to the top of the rail.
        if i != 0 {
            let moved = sessions.remove(at: i)
            sessions.insert(moved, at: 0)
        }
        persist()
    }

    func session(for id: UUID?) -> ChatSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    // MARK: - Persistence

    private static var storeURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Wick", isDirectory: true)
        // Best-effort create — failure here just means the next write
        // throws, which we already swallow.
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chat-sessions.json")
    }

    private static func loadFromDisk(at url: URL) -> [ChatSession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ChatSession].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
