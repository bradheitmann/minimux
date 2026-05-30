#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

STATE_DIR=".zig-cache/minimux-s008-holdout-state"
CAST_DIR=".zig-cache/minimux-s008-holdout-recordings"
CAST_PATH="$CAST_DIR/pane.cast"
BIN="zig-out/bin/minimux"

rm -rf "$STATE_DIR" "$CAST_DIR"
mkdir -p "$CAST_DIR"

zig build --summary all >/tmp/minimux-s008-build.log

SESSION_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" create story008)"
PANE_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" pane create --session story008 --cmd sh --json)"
PANE_ID="$(printf '%s\n' "$PANE_JSON" | jq -r '.result.pane.pane_id')"

TAP_OPEN_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" tap open "$PANE_ID" --json)"
TAP_ID="$(printf '%s\n' "$TAP_OPEN_JSON" | jq -r '.result.tap_id')"

RECORD_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" record start "$PANE_ID" --path "$CAST_PATH" --on-full error_back --json)"
REC_ID="$(printf '%s\n' "$RECORD_JSON" | jq -r '.result.recording_id')"

SEND_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" pane send "$PANE_ID" "printf 'observe-one\\n'<CR>" --json)"
WAIT_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" agent wait-idle "$PANE_ID" --timeout-ms 5000 --json)"
TIMEOUT_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" agent wait-idle "$PANE_ID" --timeout-ms 0 --json || true)"
TAP_CLOSE_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" tap close story008 "$TAP_ID" --json)"
STOP_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" record stop story008 "$REC_ID" --json)"

printf '%s\n' "$SESSION_JSON" | jq -e '.ok == true and .result.session == "story008"' >/dev/null
printf '%s\n' "$TAP_OPEN_JSON" | jq -e '.ok == true and .result.back_pressure.local == "block_control_response_until_reader_accepts_event" and .result.back_pressure.remote == "bounded_queue_close_slow_reader_on_overflow" and .result.back_pressure.ordering == "monotonic_seq_per_session"' >/dev/null
printf '%s\n' "$RECORD_JSON" | jq -e '.ok == true and .result.format == "asciicast-v2" and .result.disk_full_policy == "error_back" and .result.file_mode_octal == "600" and .result.directory_mode_octal == "700"' >/dev/null
printf '%s\n' "$SEND_JSON" | jq -e '.ok == true and (.result.stdout | contains("observe-one"))' >/dev/null
printf '%s\n' "$WAIT_JSON" | jq -e '.ok == true and .result.state == "idle" and .result.harness == "shell-generic"' >/dev/null
printf '%s\n' "$TIMEOUT_JSON" | jq -e '.ok == false and .error.detail.state == "timeout" and .error.retryable == true' >/dev/null
printf '%s\n' "$TAP_CLOSE_JSON" | jq -e '.ok == true and ([.result.events[].seq] == ([.result.events[].seq] | sort)) and (.result.events[] | select(.bytes | contains("observe-one")))' >/dev/null
printf '%s\n' "$STOP_JSON" | jq -e '.ok == true and .result.state == "stopped"' >/dev/null

grep -q '"version":2' "$CAST_PATH"
grep -q 'observe-one' "$CAST_PATH"

if stat -f '%Lp' "$CAST_PATH" >/tmp/minimux-s008-mode 2>/dev/null; then
  FILE_MODE="$(cat /tmp/minimux-s008-mode)"
  DIR_MODE="$(stat -f '%Lp' "$CAST_DIR")"
else
  FILE_MODE="$(stat -c '%a' "$CAST_PATH")"
  DIR_MODE="$(stat -c '%a' "$CAST_DIR")"
fi

test "$FILE_MODE" = "600"
test "$DIR_MODE" = "700"

MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" terminate story008 --json >/dev/null || true
echo "s008 record/tap/wait holdout PASS"
