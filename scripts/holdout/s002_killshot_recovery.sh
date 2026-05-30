#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minimux-s002.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

ZIG_CACHE="$WORK_DIR/zig-cache"
ZIG_GLOBAL_CACHE="$WORK_DIR/zig-global-cache"
ZIG_OUT="$WORK_DIR/zig-out"
STATE_DIR="$WORK_DIR/state"

cd "$ROOT"
zig build --cache-dir "$ZIG_CACHE" --global-cache-dir "$ZIG_GLOBAL_CACHE" --prefix "$ZIG_OUT" >/dev/null

BIN="$ZIG_OUT/bin/minimux"

run_json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" run --name killshot -- sh)"
daemon_pid="$(printf '%s\n' "$run_json" | jq -r '.result.daemon_pid')"
test "$daemon_pid" != "null"

MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" send killshot "echo hi<CR>" | jq -e '.ok == true' >/dev/null
MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" send killshot "export MINIMUX_KEEP=kept<CR>" | jq -e '.ok == true' >/dev/null
persist_json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" send killshot "printf \"\$MINIMUX_KEEP\"<CR>")"
printf '%s\n' "$persist_json" | jq -e '.result.stdout | contains("kept")' >/dev/null
MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" wait-idle killshot --timeout-ms 5000 | jq -e '.result.idle == true' >/dev/null

before_snapshot="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" snapshot killshot --json)"
printf '%s\n' "$before_snapshot" | jq -e '.result.visible_text | contains("echo hi") and contains("hi") and contains("MINIMUX_KEEP") and contains("kept")' >/dev/null

kill -9 "$daemon_pid" 2>/dev/null || true

if MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" send killshot "printf POSTKILL<CR>" >"$WORK_DIR/postkill-send.json" 2>/dev/null; then
  cat "$WORK_DIR/postkill-send.json"
  exit 1
fi

for _ in 1 2 3 4 5; do
  if ! kill -0 "$daemon_pid" 2>/dev/null; then
    break
  fi
  sleep 0.2
done

recovered_snapshot="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" snapshot killshot --json)"
printf '%s\n' "$recovered_snapshot" | jq -e '.result.recovery.notifications[] == "SESSION_RECOVERED"' >/dev/null
printf '%s\n' "$recovered_snapshot" | jq -e '.result.process.child_status == "dead"' >/dev/null
printf '%s\n' "$recovered_snapshot" | jq -e '.result.visible_text | contains("echo hi") and contains("hi") and contains("MINIMUX_KEEP") and contains("kept")' >/dev/null

printf '%s\n' "$recovered_snapshot"
