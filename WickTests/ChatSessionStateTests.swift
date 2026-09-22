import Foundation
import Testing
@testable import Wick

@MainActor
struct ChatSessionStateTests {
    private func makeStore() -> (ChatStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wick-chat-test-\(UUID()).json")
        return (ChatStore(storageURL: url), url)
    }

    @Test func switching_sessions_preserves_drafts_attachments_and_independent_requests() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = store.newSession()
        let a = try #require(store.state(for: first))
        a.draft = "First draft"
        a.pendingAttachments = [.document(filename: "first.csv", kind: .csv, text: "AAPL,10")]
        a.extractingCount = 1
        let requestA = try #require(a.beginResponse())
        a.pendingLabel = "First running"

        let second = store.newSession()
        let b = try #require(store.state(for: second))
        #expect(b.draft.isEmpty && b.pendingAttachments.isEmpty && b.extractingCount == 0)
        #expect(!b.pending && b.lastError == nil)
        let requestB = try #require(b.beginResponse())
        b.finishResponse(requestB, error: "Second failed")
        #expect(a.pending && a.pendingLabel == "First running" && a.lastError == nil)

        store.selectedSessionID = first
        let restored = try #require(store.state(for: first))
        #expect(restored === a)
        #expect(restored.draft == "First draft")
        #expect(restored.pendingAttachments.first?.filename == "first.csv")
        #expect(restored.beginResponse() == nil) // A view remount cannot duplicate the flight.
        a.finishResponse(requestA)
        #expect(!a.pending && b.lastError == "Second failed")
    }

    @Test func deleting_a_session_cancels_its_task_and_rejects_late_completion() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = store.newSession()
        let state = try #require(store.state(for: id))
        let request = try #require(state.beginResponse())
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        state.responseTask = task
        store.delete(id: id)
        #expect(task.isCancelled)
        #expect(!state.isCurrent(request) && !state.pending && !state.isActive)
        state.finishResponse(request, error: "Late network error")
        store.append(ChatMessage(role: .assistant, text: "Late reply"), to: id)
        #expect(state.lastError == nil && state.beginResponse() == nil)
        #expect(store.state(for: id) == nil && store.session(for: id) == nil)
        await task.value
    }

    @Test func stale_completion_cannot_clear_a_new_response() throws {
        let state = ChatSessionState()
        let old = try #require(state.beginResponse())
        state.finishResponse(old)
        let current = try #require(state.beginResponse())
        state.pendingLabel = "New response"
        state.finishResponse(old, error: "Old failure")
        #expect(state.isCurrent(current) && state.pending)
        #expect(state.pendingLabel == "New response" && state.lastError == nil)
    }

    @Test func reloading_transcripts_creates_fresh_transient_state() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = store.newSession()
        store.append(ChatMessage(role: .user, text: "Saved question"), to: id)
        let state = try #require(store.state(for: id))
        state.draft = "Unsaved draft"
        _ = state.beginResponse()
        let reloaded = ChatStore(storageURL: url)
        #expect(reloaded.session(for: id)?.messages.last?.text == "Saved question")
        #expect(reloaded.state(for: id)?.draft == "")
        #expect(reloaded.state(for: id)?.pending == false)
    }
}
