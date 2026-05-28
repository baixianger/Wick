import Foundation

#if canImport(Darwin)
/// Drives the `claude` CLI (Claude Code) as an `LLMProvider` so users with
/// a Claude Pro / Max subscription can run the Wicker workflow without
/// supplying an Anthropic API key. Each `complete(_:)` invocation spawns
/// `claude -p` as a subprocess and parses the `--output-format json`
/// reply's `result` field.
///
/// ## Two operating modes
///
/// - `.subscription` (default) — uses whatever credentials `claude login`
///   stored on this machine (OAuth → user's Claude.ai subscription).
///   **Trade-off:** each invocation re-loads the full Claude Code system
///   prompt (~44 k tokens), which is billed against subscription quota.
///   Acceptable for users without an API key; *not* cost-efficient.
///
/// - `.bare` — passes `--bare` + a custom `--system-prompt`, which skips
///   the Claude Code scaffolding and runs as a clean "thin completion."
///   Requires `ANTHROPIC_API_KEY` in the process environment (subscription
///   auth is disabled in bare mode by design). For users with an API key,
///   the existing `AnthropicProvider` direct-HTTP is still cheaper and
///   faster — `.bare` is mainly useful when you want Claude-Code's CLI
///   tooling around an otherwise thin call.
///
/// ## Limits / latency
///
/// CLI spawn cost is ~1-2 s per call on top of normal LLM latency, so a
/// full Wicker workflow (8-12 calls) adds ~10-20 s vs direct HTTP. Each
/// call is a fresh session with no prompt-cache reuse (verified against
/// `claude` 2.x with `--output-format json` — `cache_read_input_tokens`
/// stays 0 between unrelated invocations).
public struct ClaudeCodeProvider: LLMProvider {

    public enum Mode: String, Sendable {
        /// Use OAuth/subscription auth that `claude login` cached.
        case subscription
        /// Use `--bare` (strips Claude Code's default system prompt /
        /// hooks / memory) + a custom system prompt. Requires
        /// `ANTHROPIC_API_KEY` in env.
        case bare
    }

    /// Path to the `claude` binary. Defaults to bare `claude` (resolved via
    /// `PATH`), but callers can pass an absolute path when shipping a
    /// fixed install location.
    public let cliPath: String
    public let mode: Mode
    /// Hard ceiling per call so a hung subprocess doesn't wedge the
    /// workflow. Defaults to 120 s, which covers the slowest realistic
    /// Opus completion with CLI overhead.
    public let timeout: TimeInterval

    public init(cliPath: String = "claude",
                mode: Mode = .subscription,
                timeout: TimeInterval = 120)
    {
        self.cliPath = cliPath
        self.mode = mode
        self.timeout = timeout
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        let prompt = Self.flattenMessages(request.messages)
        let args = buildArguments(model: request.model, system: request.system)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            Task.detached { [cliPath, timeout] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: Self.resolveExecutable(cliPath))
                process.arguments = args + [prompt]
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError  = stderr
                // Inherit env so `ANTHROPIC_API_KEY` (for `.bare` mode) and
                // any OAuth tokens `claude login` placed in `~/.claude/`
                // are visible to the child.
                process.environment = ProcessInfo.processInfo.environment

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: LLMError.transport(
                        "Spawn failed: \(error.localizedDescription)"))
                    return
                }

                // Hard kill after `timeout` so a wedged subprocess doesn't
                // block the workflow forever. Task.sleep is detached so
                // the main wait below can race it.
                let timeoutTask = Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if process.isRunning {
                        process.terminate()
                    }
                }
                // Drain stdout + stderr on detached tasks BEFORE
                // waitUntilExit. macOS pipe buffer is ~64 KB; a real
                // `claude -p --output-format json` envelope (long
                // `result` + usage + session metadata) routinely
                // exceeds that. If we waited on exit first, the child
                // would block on `write` and the parent on
                // `waitUntilExit` → deadlock until timeout SIGTERM.
                let outReader = Task.detached {
                    stdout.fileHandleForReading.readDataToEndOfFile()
                }
                let errReader = Task.detached {
                    stderr.fileHandleForReading.readDataToEndOfFile()
                }
                process.waitUntilExit()
                timeoutTask.cancel()
                let outData = await outReader.value
                let errData = await errReader.value

                guard process.terminationStatus == 0 else {
                    let errText = String(data: errData, encoding: .utf8) ?? ""
                    let outText = String(data: outData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: LLMError.http(
                        status: Int(process.terminationStatus),
                        body: "claude exited \(process.terminationStatus): \(errText)\(outText)"))
                    return
                }

                do {
                    let reply = try JSONDecoder().decode(JSONReply.self, from: outData)
                    if reply.is_error == true {
                        continuation.resume(throwing: LLMError.http(
                            status: 500,
                            body: reply.result ?? "claude reported is_error=true"))
                        return
                    }
                    guard let text = reply.result, !text.isEmpty else {
                        continuation.resume(throwing: LLMError.empty)
                        return
                    }
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: LLMError.decoding(
                        error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Argument building

    private func buildArguments(model: String, system: String) -> [String] {
        var args: [String] = ["-p", "--output-format", "json"]
        if !model.isEmpty {
            args += ["--model", model]
        }
        switch mode {
        case .subscription:
            // Subscription mode: keep Claude Code's default system prompt
            // (which is what makes OAuth auth available) and append our
            // analyst persona.
            if !system.isEmpty {
                args += ["--append-system-prompt", system]
            }
        case .bare:
            args.append("--bare")
            if system.isEmpty {
                args += ["--system-prompt", "You are a helpful assistant."]
            } else {
                args += ["--system-prompt", system]
            }
        }
        return args
    }

    /// Wicker analysts always send exactly one user message (see
    /// `Agent.ask`), but the protocol allows multi-turn so flatten
    /// defensively. Multi-turn falls back to a `User:` / `Assistant:`
    /// transcript — Claude reads that just fine but adds tokens, so the
    /// caller should prefer single-turn when possible.
    static func flattenMessages(_ messages: [LLMMessage]) -> String {
        guard messages.count > 1 else {
            return messages.first?.content ?? ""
        }
        return messages.map { m in
            let label = m.role == .user ? "User" : "Assistant"
            return "\(label): \(m.content)"
        }.joined(separator: "\n\n")
    }

    /// `Process.executableURL` insists on an absolute path; if the caller
    /// passed a bare name like `claude`, resolve it through `PATH` rather
    /// than failing the spawn. Cached resolution is overkill — provider
    /// instances usually outlive a few thousand `claude` calls anyway.
    private static func resolveExecutable(_ pathOrName: String) -> String {
        if pathOrName.hasPrefix("/") { return pathOrName }
        let env = ProcessInfo.processInfo.environment
        let pathDirs = (env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)
        for dir in pathDirs {
            let candidate = (dir as NSString).appendingPathComponent(pathOrName)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // Fall through with the original — Process will fail with a clean
        // POSIX error the caller can surface.
        return pathOrName
    }

    // MARK: - Wire types

    /// Subset of the `claude -p --output-format json` payload. The CLI
    /// also emits `usage`, `total_cost_usd`, `session_id` etc. — none of
    /// which we consume today, so they're left undecoded.
    private struct JSONReply: Decodable {
        let type: String?
        let subtype: String?
        let is_error: Bool?
        let result: String?
    }
}
#endif
