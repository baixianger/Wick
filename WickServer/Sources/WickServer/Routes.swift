import Foundation
import Hummingbird
import NIOCore
import TradingFloor

/// HTTP endpoints over the `ReportQueue` (queue + worker pool) plus
/// an OpenAI-compatible chat endpoint that brokers any `LLMProvider`
/// the server has configured (typically OpenRouter).
///
/// - `GET  /health`                  → liveness probe
/// - `POST /report?ticker=NVDA`      → read-or-enqueue report. 200 if
///                                      cached/done, 202 if queued/running,
///                                      200+error if failed
/// - `GET  /report/:ticker/:date`    → job status (cache-only)
/// - `POST /v1/chat/completions`     → OpenAI-compatible chat broker.
///                                      Same wire format as OpenAI / OpenRouter
///                                      so the app's `OpenAICompatibleProvider`
///                                      can target it unchanged.
///
/// API surface targets Hummingbird 2.x.
func buildRouter(
    queue: ReportQueue,
    llm: any LLMProvider,
    defaultModel: String
) -> Router<BasicRequestContext> {
    let router = Router()

    router.get("health") { _, _ in "ok" }

    router.post("report") { request, _ -> Response in
        guard let ticker = request.uri.queryParameters["ticker"], !ticker.isEmpty else {
            return errorResponse(.badRequest, "Missing ?ticker=")
        }
        let status = await queue.submit(ticker: String(ticker))
        let code: HTTPResponse.Status = (status.phase == .queued || status.phase == .running)
            ? .accepted : .ok
        return try jsonResponse(status, status: code)
    }

    router.get("report/:ticker/:date") { request, context -> Response in
        let ticker = try context.parameters.require("ticker")
        let dateString = try context.parameters.require("date")
        guard let date = parseDay(dateString) else {
            return errorResponse(.badRequest, "Date must be yyyy-MM-dd")
        }
        guard let status = await queue.status(ticker: ticker, asOf: date) else {
            return errorResponse(.notFound, "No job for \(ticker) on \(dateString)")
        }
        return try jsonResponse(status)
    }

    // MARK: - OpenAI-compatible chat broker
    //
    // Same shape as OpenAI's `/v1/chat/completions` so the Wick app's
    // `OpenAICompatibleProvider` can hit this endpoint without any
    // app-side code changes — server-mode chat is now just the
    // existing OAI-compat client pointed at our base URL.
    //
    // Server-side this just forwards to whichever `LLMProvider`
    // WickServer.main wired up (OpenRouter in production), so we
    // amortise our one OpenRouter key across many app users — the
    // exact SaaS-tier promise in [[wick-business-model]]. No auth
    // for v1 dev; subscription token handling lands when we wire
    // billing.
    router.post("v1/chat/completions") { request, _ -> Response in
        let bodyBuffer = try await request.body.collect(upTo: 1_000_000)
        let bodyData = Data(buffer: bodyBuffer)
        let payload: ChatCompletionRequest
        do {
            payload = try JSONDecoder().decode(ChatCompletionRequest.self, from: bodyData)
        } catch {
            return errorResponse(.badRequest, "Bad request body: \(error)")
        }
        // Forward straight to the server's configured LLM. The model
        // string in the request is honoured if non-empty; otherwise
        // we fall back to the server's default (set at startup).
        // Extract the system prompt from the first system-role message
        // if any, per OpenAI convention.
        var systemPrompt = ""
        var convoMessages: [LLMMessage] = []
        for m in payload.messages {
            switch m.role {
            case "system":
                if !systemPrompt.isEmpty { systemPrompt += "\n\n" }
                systemPrompt += m.content
            case "user":
                convoMessages.append(LLMMessage(role: .user, content: m.content))
            case "assistant":
                convoMessages.append(LLMMessage(role: .assistant, content: m.content))
            default:
                // Unknown roles fall through silently — OpenAI also
                // tolerates the occasional unexpected role.
                continue
            }
        }
        let llmRequest = LLMRequest(
            model: payload.model.isEmpty ? defaultModel : payload.model,
            system: systemPrompt,
            messages: convoMessages,
            maxTokens: payload.max_tokens ?? 2048,
            temperature: payload.temperature ?? 0.7
        )
        do {
            let reply = try await llm.complete(llmRequest)
            let response = ChatCompletionResponse(
                id: "chatcmpl-\(UUID().uuidString.lowercased().prefix(24))",
                object: "chat.completion",
                created: Int(Date().timeIntervalSince1970),
                model: llmRequest.model,
                choices: [
                    .init(index: 0,
                          message: .init(role: "assistant", content: reply),
                          finish_reason: "stop")
                ]
            )
            return try jsonResponse(response)
        } catch {
            return errorResponse(.internalServerError,
                                 "LLM call failed: \(error.localizedDescription)")
        }
    }

    return router
}

// MARK: - OpenAI wire types (minimal subset)

/// What the app sends to `/v1/chat/completions`. We only decode the
/// fields we actually consume — `n`, `stream`, `tools`, etc. are
/// silently ignored. Extra keys don't trip the decoder because the
/// struct only lists what it cares about.
private struct ChatCompletionRequest: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }
    let model: String
    let messages: [Message]
    let max_tokens: Int?
    let temperature: Double?
}

private struct ChatCompletionResponse: Encodable {
    struct Choice: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let index: Int
        let message: Message
        let finish_reason: String
    }
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
}

// MARK: - Response helpers (manual JSON for version robustness)

private func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var buffer = ByteBuffer()
    buffer.writeBytes(try encoder.encode(value))
    return Response(status: status,
                    headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: buffer))
}

private func errorResponse(_ status: HTTPResponse.Status, _ message: String) -> Response {
    var buffer = ByteBuffer()
    buffer.writeString(#"{"error":"\#(message)"}"#)
    return Response(status: status,
                    headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: buffer))
}

private func parseDay(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: string)
}
