import Foundation
import Observation

/// ChatStore owns this state across navigation and view remounts.
@MainActor @Observable
final class ChatSessionState {
    var draft = ""
    var pendingAttachments: [ChatAttachment] = []
    var extractingCount = 0
    var attachmentError: String?
    var pendingLabel: String?
    var lastError: String?
    private(set) var pending = false
    private(set) var isActive = true
    @ObservationIgnored private var responseID: UUID?
    @ObservationIgnored var responseTask: Task<Void, Never>?

    func beginResponse() -> UUID? {
        guard isActive, !pending else { return nil }
        let id = UUID()
        responseID = id
        pending = true
        lastError = nil
        return id
    }

    func isCurrent(_ id: UUID) -> Bool {
        isActive && responseID == id
    }

    func finishResponse(_ id: UUID, error: String? = nil) {
        guard isCurrent(id) else { return }
        pending = false
        pendingLabel = nil
        lastError = error
        responseID = nil
        responseTask = nil
    }

    func invalidate() {
        isActive = false
        responseID = nil
        responseTask?.cancel()
        responseTask = nil
        pending = false
        pendingLabel = nil
    }
}
