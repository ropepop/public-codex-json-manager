# Codex Auth Rotator

Compact native macOS app for reviewing saved Codex auth files, tracking live quota data, and switching accounts from one place.

## Run

```bash
./script/build_and_run.sh
```

`swift run CodexAuthRotator` is still useful as a raw-launch fallback for diagnosing
startup issues, but it is not the normal way to launch this GUI app.

For automated checks, use safe verification mode:

```bash
./script/build_and_run.sh --verify
```

This launches against disposable auth data and does not close or relaunch real Codex windows.

## Test

```bash
swift test
```

## What It Does

- Scans a root folder full of saved `auth.json` files
- Reads live Codex quota data from the active `~/.codex/auth.json` OAuth session first, then falls back to Codex CLI
- Shows the current account, other saved accounts, and the best next account
- Updates folder suffixes with compact 5-hour and weekly usage/reset info
- Auto-prunes exact duplicate auth folders when they only contain `auth.json`
- Safely swaps `~/.codex/auth.json` after closing Codex and CodexBar
