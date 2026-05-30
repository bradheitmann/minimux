#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minimux-s011.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$ROOT"
zig build --summary all >/dev/null

mkdir -p "$WORK_DIR/docs" "$WORK_DIR/state"
cp README.md "$WORK_DIR/README.md"
cp docs/AGENTS.md "$WORK_DIR/docs/AGENTS.md"
cp zig-out/bin/minimux "$WORK_DIR/minimux"
chmod +x "$WORK_DIR/minimux"

BIN="$WORK_DIR/minimux"
STATE_DIR="$WORK_DIR/state"
SESSION="s011-docs"

run_json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" run --name "$SESSION" -- sh)"
daemon_pid="$(printf '%s\n' "$run_json" | jq -r '.result.daemon_pid')"
printf '%s\n' "$run_json" | jq -e '.ok == true and .result.recovery.state == "clean"' >/dev/null

send_json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" send "$SESSION" "printf 'docs-first-contact\\n'<CR>")"
printf '%s\n' "$send_json" | jq -e '.ok == true and (.result.stdout | contains("docs-first-contact"))' >/dev/null

MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" wait-idle "$SESSION" --timeout-ms 5000 | jq -e '.ok == true and .result.idle == true' >/dev/null
MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" snapshot "$SESSION" --json | jq -e '.ok == true and .result.recovery.state == "clean" and (.result.visible_text | contains("docs-first-contact"))' >/dev/null

kill -9 "$daemon_pid" 2>/dev/null || true

recovered_json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" snapshot "$SESSION" --json)"
printf '%s\n' "$recovered_json" | jq -e '.ok == true and .result.recovery.state == "recovered" and (.result.recovery.notifications | index("SESSION_RECOVERED"))' >/dev/null
printf '%s\n' "$recovered_json" | jq -e '.result.visible_text | contains("docs-first-contact")' >/dev/null

printf '%s\n' "$recovered_json"
