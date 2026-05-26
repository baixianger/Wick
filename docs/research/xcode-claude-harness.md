# Reverse-engineering Xcode 26's Claude Agent

Date: 2026-05-26
Xcode version: 26.5 (17F42)
Apple-bundled Claude Code binary: 2.1.118 (auto-updated from 2.1.113 during the session)
Capture method: mitmproxy reverse-proxy on `localhost:8080`, with
`launchctl setenv ANTHROPIC_BASE_URL=https://localhost:8080` and
`launchctl setenv NODE_EXTRA_CA_CERTS=~/.mitmproxy/mitmproxy-ca-cert.pem`.

## TL;DR

Xcode's "Claude" agent is **the real Claude Code CLI**, signed by Anthropic
(team `Q6L2SF6YDW`, identifier `com.anthropic.claude-code`), launched as a
subprocess and driven over stream-json stdio. Apple does **not** rewrite the
system prompt. Apple's contributions are:

1. **Default model = Opus 4.7** (CLI defaults to Sonnet).
2. **17 MCP tools** exposing Xcode IDE capabilities via `xcrun mcpbridge`.
3. **A `UserPromptSubmit` hook** that injects an `XcodeLS`-derived project tree
   on every turn.
4. **Working directory = the Xcode workspace root.**
5. **Subagent dispatch (Task → Haiku 4.5)** for exploration work.

That combination — Opus + project-aware tools + per-turn LS injection + cheap
Haiku for exploration — is why retrieval feels noticeably better than vanilla
Claude Code from a terminal.

## How Apple launches the agent

`xcrun mcpbridge run-agent --dry-run claude` prints the exact launch line:

```
Executable: ~/Library/Developer/Xcode/CodingAssistant/Agents/XcodeVersions/17F42/claude/claude
Signing:    team=Q6L2SF6YDW, identifier=com.anthropic.claude-code

Environment variables (from Xcode):
  ANTHROPIC_MODEL=best
  CLAUDE_CONFIG_DIR=~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig
  MCP_XCODE_PID=<pid>

Full command:
  claude --verbose \
    --mcp-config /var/folders/.../mcp-config-<uuid>.json \
    --settings '{"env":{"CLAUDE_CODE_ENABLE_TELEMETRY":"0","DISABLE_TELEMETRY":"1"},"hasCompletedOnboarding":true}'
```

The MCP config file is auto-generated per launch:

```json
{
  "mcpServers": {
    "xcode-tools": {
      "command": "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge",
      "type": "stdio"
    }
  }
}
```

So Apple wires Xcode → `mcpbridge` (XPC to Xcode's `com.apple.dt.mcpbridge.tool-service`)
→ `claude` (subprocess) → `mcpbridge` (again, as the MCP server `xcode-tools`).
Claude talks to Xcode round-trip through this same bridge binary.

Apple also recognizes four custom environment variables (seen as literals in
`IDEIntelligenceAgents.framework`): `ANTHROPIC_BASE_URL`, `NODE_EXTRA_CA_CERTS`,
`APPLE_CLAUDE_CODE_PROXY_PORT`, `APPLE_CLAUDE_CODE_DANGEROUSLY_BYPASS_HOOKS`.

## Captured API request structure

Every Xcode agent turn becomes a `POST https://api.anthropic.com/v1/messages?beta=true`
with a `claude-cli/2.1.118 (external, sdk-cli)` user-agent. The body schema:

```jsonc
{
  "model": "claude-opus-4-7",                  // main; subagents use haiku-4-5
  "max_tokens": 64000,
  "temperature": null,
  "stream": true,
  "metadata": { "user_id": "{\"device_id\":...,\"account_uuid\":...,\"session_id\":...}" },
  "context_management": null,
  "output_config": null,

  "system": [
    { "text": "x-anthropic-billing-header: cc_version=2.1.118.b8c; cc_entrypoint=sdk-cli; cch=06ef0;" },
    { "text": "You are Claude Code, Anthropic's official CLI for Claude, running within the Claude Agent SDK.",
      "cache_control": { "type": "ephemeral" } },
    { "text": "<the standard ~30 KB Claude Code system prompt, including a dynamic gitStatus tail>",
      "cache_control": { "type": "ephemeral" } }
  ],

  "tools": [ ... 43 entries: Claude Code built-ins + user MCP servers + 17 xcode-tools ... ],
  "messages": [ ... ]
}
```

Notable design points:

- The "system prompt" is **vanilla Claude Code**, identical to a terminal CLI
  run. Apple appends nothing here.
- The standard prompt's tail dynamically includes `git status`, recent commits,
  branch name — same as in CLI runs.
- The billing header is smuggled in as `system[0]` rather than an HTTP header,
  which is how Claude Code conveys version/entrypoint to the API.
- `cache_control: { type: "ephemeral" }` is applied per system block so prompt
  caching kicks in across turns.

## Apple's actual additions: `<system-reminder>` blocks at the top of `messages[0]`

This is where the Apple flavor lives. Verbatim excerpt from a Wick turn where
the user asked `"can you scan my code and pick out the bad practises."`:

```
<system-reminder># MCP Server Instructions

The following MCP servers have provided instructions for how to use their tools:

## xcode-tools
Request Xcode perform the action you specify.
</system-reminder>

<system-reminder>The following skills are available for use with the Skill tool:
- update-config: ...
- ...
</system-reminder>

<system-reminder>
UserPromptSubmit hook additional context: Project structure:
Wick/Packages/TradingFloor/Package.swift
Wick/Packages/TradingFloor/Sources/TradingFloor/Agents/Agents.swift
Wick/Packages/TradingFloor/Sources/TradingFloor/Agents/ChatAgent.swift
... [~5800 chars of project tree, regenerated every turn] ...
</system-reminder>

<system-reminder>As you answer the user's questions, you can use the following context:
# userEmail
The user's email address is xiang@omika.ai.
# currentDate
Today's date is 2026-05-26.
</system-reminder>

can you scan my code and pick out the bad practises.
```

Mapped to mechanisms:

- The `# MCP Server Instructions` block: standard Claude Code MCP onboarding.
- The skills block: the **user's** Claude Code skills (not Apple's). Apple
  passes the user's `~/.claude` config through unchanged.
- The **`UserPromptSubmit hook additional context: Project structure:` block**:
  this is the smoking gun for `AgentUserPromptSubmitHook` seen in
  `IDEIntelligenceAgents.framework` strings. The hook calls `XcodeLS` to
  produce a project file tree and prepends it to every user turn.
- The `userEmail` / `currentDate` block: standard Claude Code "additional
  context" injection.

Caveat: the LS tree reflects Xcode's **project organization**, which can
disagree with the on-disk layout. In this capture, the project hint listed
`Wick/Packages/TradingFloor/...` while on disk the package lives at
`Wick/TradingFloor/`. The main turn caught this and told the subagent to ignore
the bogus paths. Heuristic for users: don't trust the LS hint as ground truth.

## The 17 `xcode-tools` MCP tools

Captured live from a real request body's `tools[]` array. Names + one-line
descriptions:

| Tool | Purpose |
|---|---|
| `XcodeLS` | List files/dirs in **Xcode project structure** (not filesystem). |
| `XcodeGlob` | Glob over Xcode project structure. |
| `XcodeGrep` | Regex search over Xcode project files. |
| `XcodeRead` | Read a project file, `cat -n` format, supports `offset`/`limit`. |
| `XcodeWrite` | Create/overwrite project file; auto-adds to `.xcodeproj`. |
| `XcodeUpdate` | str_replace edits in a project file. |
| `XcodeMakeDir` | Create directories/groups in the project. |
| `XcodeMV` | Move/rename in the project navigator, with optional FS op. |
| `XcodeRM` | Remove from project, with optional FS deletion. |
| `BuildProject` | Build the project, wait, return result. |
| `GetBuildLog` | Filtered log of the latest build, by severity/pattern. |
| `RunAllTests` | Run all tests in the active scheme's plan. |
| `RunSomeTests` | Run a specified subset. |
| `GetTestList` | Enumerate available tests (up to 100). |
| `XcodeListNavigatorIssues` | Current Issue Navigator entries. |
| `XcodeRefreshCodeIssuesInFile` | Live `swiftc` diagnostics for a file. |
| `ExecuteSnippet` | Compile + run a code snippet in the context of a file. |
| `RenderPreview` | Snapshot a SwiftUI `#Preview` and return the image. |
| `DocumentationSearch` | **Semantic search of Apple Developer Documentation.** |

(`ListMcpResourcesTool` and `ReadMcpResourceTool` from Claude Code are present
too but are generic, not Apple-specific.)

There is **no `query_search` / vector codebase search** in the agent mode.
That tool exists in the lighter "Xcode Intelligence chat" mode (visible in
`IDEIntelligenceChat.framework` strings) but the full agent harness relies on
plain project-scoped glob/grep/read plus the semantic Apple Developer Docs
search.

## Two-tier model dispatch

In the captured Wick session:

| Role | Model | Flows | Purpose |
|---|---|---|---|
| Main conversation | `claude-opus-4-7` | 7 | User-facing turns. |
| Subagent | `claude-haiku-4-5-20251001` | 25 | "File search specialist" via Task. |

The subagent's system prompt is the standard Claude Code subagent prompt:

> *You are a file search specialist for Claude Code, Anthropic's official CLI
> for Claude. ... === CRITICAL: READ-ONLY MODE - NO FILE MODIFICATIONS === ...*

So Apple isn't doing anything novel here — they're just using Claude Code's
built-in Task → Explore subagent pattern, dispatched from Opus. The cost
discipline: keep Opus focused; let Haiku 4.5 thrash through Glob/Grep/Read.

## Why this answers "why is retrieval better in Xcode?"

1. **Model floor is Opus 4.7.** Same prompt, smarter model.
2. **Project structure is in front of Claude on every turn**, via the
   `UserPromptSubmit` hook injection. No need to ask "what's here".
3. **`XcodeGlob`/`XcodeGrep`/`XcodeRead` operate on the Xcode project tree**,
   not the raw filesystem — so no `.build`, no `DerivedData`, no noise.
4. **Live `swiftc` diagnostics via `XcodeRefreshCodeIssuesInFile`** — Claude
   can ask "what's broken right now?" and get real compiler output instead of
   re-running `swift build` and parsing stderr.
5. **`DocumentationSearch` against Apple's own vector index** for SDK APIs —
   far better than web search for Apple-platform questions.
6. **Subagent dispatch keeps Opus context lean** while still doing thorough
   exploration.

Nothing magical about the prompt itself. The harness is doing the lifting.

## Things that did NOT work, and why (for future reference)

- **Binary shim** (replace `claude` with a tee-shim that logs stdio): blocked.
  Apple validates the agent's code signature against Anthropic's team OU at
  chat-launch time. Error: *"The code signing identity for the agent did not
  match expectations"*. The `auth status` invocation Xcode runs at startup did
  not validate, so the shim caught one trivial flow before failing.
- **`dtrace` / `lldb` attach**: blocked. Claude binary uses the hardened
  runtime (`flags=0x10000`), so SIP refuses task-attach.
- **`DYLD_INSERT_LIBRARIES`**: blocked, same reason.
- **mitmproxy in regular-proxy mode + `ANTHROPIC_BASE_URL=https://localhost:8080`**:
  partially worked — claude treated localhost as the API endpoint and POSTed
  full request bodies with absolute paths, but mitmproxy in normal mode killed
  the connections because it had no "real" upstream to forward to. Switching
  mitmproxy to `--mode reverse:https://api.anthropic.com` fixed it.
- **System-keychain CA trust for the MITM cert**: failed in this run because
  `osascript with administrator privileges` couldn't authenticate the second
  challenge (`SecTrustSettingsSetTrustSettings`). Setting `NODE_EXTRA_CA_CERTS`
  on the env was sufficient on its own, no keychain mutation needed.

## Reproduction recipe

The scripts live in [`scripts/`](../../scripts):

- `claude-shim.sh` + `claude-intercept.sh on|off|status` — the dead-end shim
  approach. Kept around as a reference.
- `mitm-cleanup.sh` — revert the launchctl env, kill mitmproxy, remove the
  system-keychain cert (best-effort).

To re-run the live capture (Xcode 26+, `mitmproxy` from Homebrew):

```bash
# one-time: brew install mitmproxy; touch the CA so ~/.mitmproxy exists
mitmdump --listen-port 18080 & sleep 3 && pkill mitmdump

# quit any open Xcode first
osascript -e 'tell application "Xcode" to quit'

# set env on launchd so newly-spawned Xcode inherits it
launchctl setenv ANTHROPIC_BASE_URL "https://localhost:8080"
launchctl setenv NODE_EXTRA_CA_CERTS "$HOME/.mitmproxy/mitmproxy-ca-cert.pem"

# start the proxy in reverse mode
mitmweb \
  --mode reverse:https://api.anthropic.com \
  --listen-port 8080 --web-port 8081 \
  --save-stream-file /tmp/wick-mitm/flows.mitm &

# reopen Xcode → use the chat → analyze /tmp/wick-mitm/flows.mitm
open Wick.xcodeproj
# ... use chat ...

# clean up
./scripts/mitm-cleanup.sh
```

The flow file is a mitmproxy on-wire format. Decode with:

```python
from mitmproxy import http, io
import json
with open("/tmp/wick-mitm/flows.mitm","rb") as f:
    flows = [fl for fl in io.FlowReader(f).stream() if isinstance(fl, http.HTTPFlow)]
for fl in flows:
    body = fl.request.get_content()        # raw bytes
    if fl.request.method == "POST":
        payload = json.loads(body)
        # payload['system'], payload['tools'], payload['messages']
```

## Open questions / not yet captured

- What does `APPLE_CLAUDE_CODE_DANGEROUSLY_BYPASS_HOOKS` actually disable?
  Likely the `UserPromptSubmit` hook injection. Untested.
- Where does `RenderPreview` upload the rendered image? In-band as a
  base64-encoded `image` content block in the tool result, or via a side-channel?
  Not yet captured.
- The Xcode "Intelligence chat" mode (a simpler chat that lives in
  `IDEIntelligenceChat.framework`) has a different tool surface including
  `query_search` (vector index) and `classify_user_intent`. That's a separate
  harness from the agent mode dissected here. Worth a follow-up capture.
- Does Apple expose a per-Xcode-scheme version of `BuildProject` (vs a default)?
- What does the response to `DocumentationSearch` look like on the wire?
  Probably a list of doc-archive URLs + snippets — also unverified.
