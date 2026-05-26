#!/bin/bash
# Install / uninstall the Wick Claude interception shim.
#   ./claude-intercept.sh on    — back up real binary, install shim
#   ./claude-intercept.sh off   — restore real binary
#   ./claude-intercept.sh status — show current state

set -euo pipefail
CLAUDE_DIR="$HOME/Library/Developer/Xcode/CodingAssistant/Agents/claude/2.1.113"
REAL="$CLAUDE_DIR/claude"
BACKUP="$CLAUDE_DIR/claude.real"
SHIM_SRC="$(cd "$(dirname "$0")" && pwd)/claude-shim.sh"

case "${1:-status}" in
  on)
    if [ -f "$BACKUP" ]; then
      echo "shim already installed (backup exists at $BACKUP)" >&2
      exit 1
    fi
    if [ ! -f "$SHIM_SRC" ]; then
      echo "missing $SHIM_SRC" >&2; exit 1
    fi
    mv "$REAL" "$BACKUP"
    cp "$SHIM_SRC" "$REAL"
    chmod +x "$REAL"
    echo "installed. trace dir: ${WICK_CLAUDE_TRACE_DIR:-/tmp/wick-claude-trace}"
    echo "Xcode may prompt 'agent binary has been updated' — approve to continue."
    ;;
  off)
    if [ ! -f "$BACKUP" ]; then
      echo "no backup at $BACKUP — nothing to restore" >&2; exit 1
    fi
    rm -f "$REAL"
    mv "$BACKUP" "$REAL"
    echo "restored. Xcode will likely ask to re-approve the (now-original) binary."
    ;;
  status)
    if [ -f "$BACKUP" ]; then
      echo "SHIM ACTIVE  ($REAL is shim, real binary at $BACKUP)"
    else
      echo "no shim. $REAL is the original signed binary."
    fi
    codesign -dv "$REAL" 2>&1 | head -5 || true
    ;;
  *)
    echo "usage: $0 {on|off|status}" >&2; exit 2 ;;
esac
