#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${MINIMUX_BIN:-$ROOT_DIR/zig-out/bin/minimux}"

usage() {
  printf 'Usage: bash examples/prototype.sh --check\n'
}

if [[ "${1:-}" != "--check" ]]; then
  usage
  exit 2
fi

if [[ ! -x "$BIN" ]]; then
  (cd "$ROOT_DIR" && zig build --summary all >/dev/null)
fi

STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minimux-prototype.XXXXXX")"
SESSION="mx-docs-$$"
DAEMON_PID=""

cleanup() {
  if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" terminate "$SESSION" --json >/dev/null 2>&1 || kill "$DAEMON_PID" 2>/dev/null || true
  fi
  rm -rf "$STATE_DIR"
}
trap cleanup EXIT

run_json="$STATE_DIR/run.json"
send_json="$STATE_DIR/send.json"
wait_json="$STATE_DIR/wait-idle.json"
snapshot_json="$STATE_DIR/snapshot.json"
recovered_json="$STATE_DIR/recovered-snapshot.json"

MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" run --name "$SESSION" -- sh > "$run_json"
DAEMON_PID="$(jq -r '.result.daemon_pid' "$run_json")"
jq -e '.ok == true and .result.state == "running" and .result.recovery.state == "clean"' "$run_json" >/dev/null

MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" send "$SESSION" "printf 'minimux-docs-011\n'<CR>" > "$send_json"
jq -e '.ok == true and (.result.stdout | contains("minimux-docs-011"))' "$send_json" >/dev/null

MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" wait-idle "$SESSION" --timeout-ms 5000 > "$wait_json"
jq -e '.ok == true and .result.state == "idle" and .result.idle == true' "$wait_json" >/dev/null

MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" snapshot "$SESSION" --json > "$snapshot_json"
jq -e '.ok == true and .result.recovery.state == "clean" and (.result.visible_text | contains("minimux-docs-011"))' "$snapshot_json" >/dev/null

kill -9 "$DAEMON_PID" 2>/dev/null || true
sleep 0.2

MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" snapshot "$SESSION" --json > "$recovered_json"
jq -e '.ok == true and .result.recovery.state == "recovered" and (.result.recovery.notifications | index("SESSION_RECOVERED")) and (.result.visible_text | contains("minimux-docs-011"))' "$recovered_json" >/dev/null

printf 'PASS examples/prototype.sh --check\n'
