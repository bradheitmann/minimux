#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minimux-s013.XXXXXX")"
pids=()

cleanup() {
  for pid in "${pids[@]:-}"; do
    kill -9 "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

ZIG_CACHE="$WORK_DIR/zig-cache"
ZIG_GLOBAL_CACHE="$WORK_DIR/zig-global-cache"
ZIG_OUT="$WORK_DIR/zig-out"
STATE_DIR="$WORK_DIR/state"
RECORD_DIR="$WORK_DIR/recordings"
BIN="$ZIG_OUT/bin/minimux"

cd "$ROOT"
mkdir -p "$RECORD_DIR"
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

for cycle in 1 2 3; do
  session="stress-$cycle"
  cols=$((80 + cycle))
  rows=$((24 + cycle))
  cast_path="$RECORD_DIR/$session.cast"

  create_json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" create "$session")"
  printf '%s\n' "$create_json" | jq -e --arg session "$session" '.ok == true and .result.session == $session and .result.state == "running"' >/dev/null
  daemon_pid="$(printf '%s\n' "$create_json" | jq -r '.result.daemon_pid')"
  pids+=("$daemon_pid")

  pane_json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" pane create --session "$session" --cmd sh --cols "$cols" --rows "$rows" --json)"
  pane_id="$(printf '%s\n' "$pane_json" | jq -r '.result.pane.pane_id')"
  printf '%s\n' "$pane_json" | jq -e --arg pane "$pane_id" --argjson cols "$cols" --argjson rows "$rows" \
    '.ok == true and .result.pane.pane_id == $pane and .result.pane.dimensions.cols == $cols and .result.pane.dimensions.rows == $rows' >/dev/null

  tap_open_json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" tap open "$pane_id" --json)"
  tap_id="$(printf '%s\n' "$tap_open_json" | jq -r '.result.tap_id')"
  printf '%s\n' "$tap_open_json" | jq -e '.ok == true and .result.back_pressure.ordering == "monotonic_seq_per_session"' >/dev/null

  record_json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" record start "$pane_id" --path "$cast_path" --on-full error_back --json)"
  rec_id="$(printf '%s\n' "$record_json" | jq -r '.result.recording_id')"
  printf '%s\n' "$record_json" | jq -e '.ok == true and .result.format == "asciicast-v2" and .result.file_mode_octal == "600"' >/dev/null

  for event in 1 2 3 4; do
    marker="$session-event-$event"
    send_json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" pane send "$pane_id" "printf '$marker\\n'<CR>" --json)"
    printf '%s\n' "$send_json" | jq -e --arg marker "$marker" '.ok == true and (.result.stdout | contains($marker))' >/dev/null
    MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" agent wait-idle "$pane_id" --timeout-ms 5000 --json \
      | jq -e '.ok == true and .result.idle == true' >/dev/null
  done

  snapshot_json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" pane snapshot "$pane_id" --json)"
  printf '%s\n' "$snapshot_json" | jq -e --arg marker "$session-event-4" --argjson cols "$cols" --argjson rows "$rows" \
    '.ok == true and .result.snapshot.dimensions.cols == $cols and .result.snapshot.dimensions.rows == $rows and (.result.snapshot.visible_text | contains($marker))' >/dev/null

  tap_close_json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" tap close "$session" "$tap_id" --json)"
  printf '%s\n' "$tap_close_json" | jq -e --arg marker "$session-event-4" \
    '.ok == true and ([.result.events[].seq] == ([.result.events[].seq] | sort)) and any(.result.events[]; .bytes | contains($marker))' >/dev/null

  stop_json="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" record stop "$session" "$rec_id" --json)"
  printf '%s\n' "$stop_json" | jq -e '.ok == true and .result.state == "stopped"' >/dev/null
  grep -q '"version":2' "$cast_path"
  grep -q "$session-event-4" "$cast_path"

  clean_snapshot="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" snapshot "$session" --json)"
  printf '%s\n' "$clean_snapshot" | jq -e --arg marker "$session-event-4" \
    '.ok == true and .result.recovery.state == "clean" and (.result.visible_text | contains($marker))' >/dev/null

  kill -9 "$daemon_pid" 2>/dev/null || true
  wait_dead "$daemon_pid"

  recovered_snapshot="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" snapshot "$session" --json)"
  printf '%s\n' "$recovered_snapshot" | jq -e --arg marker "$session-event-4" \
    '.ok == true and .result.recovery.state == "recovered" and (.result.recovery.notifications | index("SESSION_RECOVERED")) and .result.process.child_status == "dead" and (.result.visible_text | contains($marker))' >/dev/null
done

echo "s013 repeated observe/recovery stress holdout PASS"
