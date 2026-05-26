#!/bin/bash
# Wick interception shim — replaces ~/Library/Developer/Xcode/CodingAssistant/Agents/claude/2.1.113/claude.
# Logs argv, env (filtered), stdin (toward claude), stdout/stderr (from claude) into TRACE_DIR.
# Then execs the real Anthropic-signed binary stashed as `claude.real`.

set -u
REAL="$HOME/Library/Developer/Xcode/CodingAssistant/Agents/claude/2.1.113/claude.real"
TRACE_DIR="${WICK_CLAUDE_TRACE_DIR:-/tmp/wick-claude-trace}"
mkdir -p "$TRACE_DIR"
TS=$(date +%Y%m%d-%H%M%S)-$$
BASE="$TRACE_DIR/$TS"

{
  echo "=== invocation ==="
  echo "ts:   $TS"
  echo "pid:  $$"
  echo "ppid: $PPID"
  echo "cwd:  $(pwd)"
  echo "real: $REAL"
  echo "--- argv ---"
  printf '%q\n' "$0" "$@"
  echo "--- env (claude/anthropic/mcp/xcode/apple_claude) ---"
  env | grep -E '^(ANTHROPIC|CLAUDE|MCP|XCODE|APPLE_CLAUDE|DISABLE_TELEMETRY|NODE_)' | sort
  echo "--- end ---"
} > "$BASE.meta" 2>&1

# Pipe stdin through a tee so we capture every JSON message Apple feeds claude,
# and tee stdout/stderr so we capture every response back.
exec tee "$BASE.stdin" | "$REAL" "$@" \
  > >(tee "$BASE.stdout") \
  2> >(tee "$BASE.stderr" >&2)
