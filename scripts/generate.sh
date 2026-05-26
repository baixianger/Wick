#!/usr/bin/env bash
# Regenerate Wick.xcodeproj from project.yml.
# Run after editing project.yml or adding/removing source folders.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not installed. Run: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate
echo "Wick.xcodeproj regenerated."
