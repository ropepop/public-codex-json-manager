#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexAuthRotator"
BUNDLE_ID="com.jolkins.codexauthrotator"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
PID_FILE="$DIST_DIR/$APP_NAME.pid"

stop_previous_script_instance() {
  if [[ ! -f "$PID_FILE" ]]; then
    return
  fi

  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
    rm -f "$PID_FILE"
    return
  fi

  local args
  args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  if [[ "$args" != *"$APP_BINARY"* ]]; then
    rm -f "$PID_FILE"
    return
  fi

  kill "$pid" >/dev/null 2>&1 || true
  for _ in {1..40}; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  rm -f "$PID_FILE"
}

cd "$ROOT_DIR"
stop_previous_script_instance
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Codex Auth Rotator</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  local before_pids
  before_pids="$(pgrep -f "$APP_BINARY" 2>/dev/null || true)"

  if [[ "$#" -gt 0 ]]; then
    /usr/bin/open -n "$APP_BUNDLE" --args "$@"
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi

  for _ in {1..40}; do
    local after_pids pid
    after_pids="$(pgrep -f "$APP_BINARY" 2>/dev/null || true)"
    for pid in $after_pids; do
      if ! grep -qx "$pid" <<<"$before_pids"; then
        echo "$pid" >"$PID_FILE"
        return 0
      fi
    done
    sleep 0.1
  done

  return 1
}

cleanup_pid_file_process() {
  if [[ ! -f "$PID_FILE" ]]; then
    return
  fi

  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$PID_FILE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --verify|verify)
    SAFE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-auth-rotator-safe.XXXXXX")"
    trap 'cleanup_pid_file_process; rm -rf "$SAFE_ROOT"' EXIT
    open_app --safe-verification --safe-verification-root "$SAFE_ROOT"
    sleep 1
    if [[ ! -f "$PID_FILE" ]] || ! kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
      echo "verification launch failed" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--verify]" >&2
    exit 2
    ;;
esac
