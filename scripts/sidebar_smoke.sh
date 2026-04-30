#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="${1:-$REPO_DIR/.build/arm64-apple-macosx/debug/CodexAuthRotator}"
TOGGLES="${TOGGLES:-8}"
LOG_PATH="${TMPDIR:-/tmp}/codex-auth-rotator-sidebar-smoke.log"
SAFE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-auth-rotator-sidebar-safe.XXXXXX")"

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "Missing executable: $BINARY_PATH" >&2
  exit 1
fi

CODEX_AUTH_ROTATOR_SAFE_VERIFICATION=1 CODEX_AUTH_ROTATOR_SAFE_ROOT="$SAFE_ROOT" "$BINARY_PATH" >"$LOG_PATH" 2>&1 &
APP_PID=$!

cleanup() {
  kill "$APP_PID" >/dev/null 2>&1 || true
  wait "$APP_PID" >/dev/null 2>&1 || true
  rm -rf "$SAFE_ROOT"
}
trap cleanup EXIT

for _ in {1..40}; do
  if osascript -e "tell application \"System Events\" to count (every process whose unix id is $APP_PID)" 2>/dev/null | grep -q '[1-9]'; then
    break
  fi
  sleep 0.25
done

osascript >/dev/null <<APPLESCRIPT
tell application "System Events"
  tell (first process whose unix id is $APP_PID)
    set frontmost to true
    perform action "AXRaise" of window 1
  end tell
end tell
APPLESCRIPT

for ((i = 1; i <= TOGGLES; i++)); do
  osascript >/dev/null <<APPLESCRIPT
tell application "System Events"
  tell (first process whose unix id is $APP_PID)
    set frontmost to true
  end tell
  keystroke "r" using {command down}
end tell
APPLESCRIPT

  sleep 0.3

  if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    echo "Sidebar smoke failed after toggle $i. See $LOG_PATH" >&2
    exit 1
  fi
done

echo "Sidebar smoke passed after $TOGGLES toggles."
