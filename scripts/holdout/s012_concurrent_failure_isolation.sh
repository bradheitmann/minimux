#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minimux-s012.XXXXXX")"

alpha_pid=""
beta_pid=""

cleanup() {
  if [ -n "$alpha_pid" ]; then
    kill -9 "$alpha_pid" 2>/dev/null || true
  fi
  if [ -n "$beta_pid" ]; then
    kill -9 "$beta_pid" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

ZIG_CACHE="$WORK_DIR/zig-cache"
ZIG_GLOBAL_CACHE="$WORK_DIR/zig-global-cache"
ZIG_OUT="$WORK_DIR/zig-out"
STATE_DIR="$WORK_DIR/state"
BIN="$ZIG_OUT/bin/minimux"

cd "$ROOT"
zig build --cache-dir "$ZIG_CACHE" --global-cache-dir "$ZIG_GLOBAL_CACHE" --prefix "$ZIG_OUT" >/dev/null

wait_dead() {
  local pid="$1"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  printf 'daemon pid still alive after SIGKILL: %s\n' "$pid" >&2
  return 1
}

start_session() {
  local name="$1"
  local json
  json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" run --name "$name" -- sh)"
  printf '%s\n' "$json" | jq -e --arg name "$name" '.ok == true and .result.session == $name and .result.recovery.state == "clean"' >/dev/null
  printf '%s\n' "$json" | jq -r '.result.daemon_pid'
}

send_marker() {
  local session="$1"
  local marker="$2"
  local json
  json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" send "$session" "printf '$marker\\n'<CR>")"
  printf '%s\n' "$json" | jq -e --arg marker "$marker" '.ok == true and (.result.stdout | contains($marker))' >/dev/null
  MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" wait-idle "$session" --timeout-ms 5000 | jq -e '.ok == true and .result.idle == true' >/dev/null
}

alpha_pid="$(start_session iso-alpha)"
beta_pid="$(start_session iso-beta)"
test "$alpha_pid" != "$beta_pid"

send_marker iso-alpha "alpha-before-kill"
send_marker iso-beta "beta-before-kill"

MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" list --json \
  | jq -e '.ok == true and (.result.sessions | length) == 2 and ([.result.sessions[].daemon_alive] | all)' >/dev/null

kill -9 "$alpha_pid" 2>/dev/null || true
wait_dead "$alpha_pid"

if MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" send iso-alpha "printf 'alpha-after-kill\\n'<CR>" >"$WORK_DIR/alpha-postkill.json" 2>/dev/null; then
  cat "$WORK_DIR/alpha-postkill.json"
  exit 1
fi

MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" attach iso-beta --json \
  | jq -e --arg pid "$beta_pid" '.ok == true and .result.session.daemon_alive == true and (.result.session.daemon_pid | tostring) == $pid' >/dev/null
send_marker iso-beta "beta-after-alpha-kill"

alpha_recovered="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" snapshot iso-alpha --json)"
printf '%s\n' "$alpha_recovered" \
  | jq -e '.ok == true and .result.recovery.state == "recovered" and (.result.recovery.notifications | index("SESSION_RECOVERED")) and .result.process.child_status == "dead"' >/dev/null
printf '%s\n' "$alpha_recovered" \
  | jq -e '(.result.visible_text | contains("alpha-before-kill")) and (.result.visible_text | contains("beta-before-kill") | not)' >/dev/null

beta_clean="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" snapshot iso-beta --json)"
printf '%s\n' "$beta_clean" \
  | jq -e '.ok == true and .result.recovery.state == "clean" and (.result.visible_text | contains("beta-before-kill")) and (.result.visible_text | contains("beta-after-alpha-kill"))' >/dev/null

kill -9 "$beta_pid" 2>/dev/null || true
wait_dead "$beta_pid"

beta_recovered="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" snapshot iso-beta --json)"
printf '%s\n' "$beta_recovered" \
  | jq -e '.ok == true and .result.recovery.state == "recovered" and (.result.recovery.notifications | index("SESSION_RECOVERED")) and .result.process.child_status == "dead"' >/dev/null
printf '%s\n' "$beta_recovered" \
  | jq -e '(.result.visible_text | contains("beta-before-kill")) and (.result.visible_text | contains("beta-after-alpha-kill")) and (.result.visible_text | contains("alpha-before-kill") | not)' >/dev/null

echo "s012 concurrent failure isolation holdout PASS"
