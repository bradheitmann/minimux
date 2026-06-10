#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

STATE_DIR=".zig-cache/minimux-s014-holdout-state"
BIN="zig-out/bin/minimux"

rm -rf "$STATE_DIR"

zig build --summary all >/tmp/minimux-s014-build.log

SESSION_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" create s014)"
printf '%s\n' "$SESSION_JSON" | jq -e '.ok == true' >/dev/null

PANE_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" pane create --session s014 --cmd sh --json)"
PANE_ID="$(printf '%s\n' "$PANE_JSON" | jq -r '.result.pane.pane_id')"

# Fill the pane screen so its snapshot exceeds the old 64KB CLI read buffer.
MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" pane send "$PANE_ID" "printf '%01900d' 0 | tr 0 x<CR>" --json >/dev/null
MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" agent wait-idle "$PANE_ID" --timeout-ms 5000 --json >/dev/null

SNAPSHOT_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" pane snapshot "$PANE_ID" --json)"
SNAPSHOT_BYTES="${#SNAPSHOT_JSON}"
test "$SNAPSHOT_BYTES" -gt 65536
printf '%s\n' "$SNAPSHOT_JSON" | jq -e '.ok == true and (.result.snapshot.visible_text | contains("xxxx"))' >/dev/null

ATTACH_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" attach s014 --json)"
SOCKET="$(printf '%s\n' "$ATTACH_JSON" | jq -r '.result.session.control_socket')"
DAEMON_PID="$(printf '%s\n' "$ATTACH_JSON" | jq -r '.result.session.daemon_pid')"

DAEMON_LOG="$STATE_DIR/sessions/s014/daemon.log"

wait_for_contained_failures() {
  expected_count="$1"
  for _ in $(seq 1 50); do
    if [ "$(grep -c 'failed: ' "$DAEMON_LOG" 2>/dev/null || printf '0')" -ge "$expected_count" ]; then
      return 0
    fi
    sleep 0.2
  done
  printf 'daemon never logged contained failure %s\n' "$expected_count" >&2
  return 1
}

# A client that requests the oversized snapshot and disconnects after one
# byte must cost itself the response, not the daemon its life.
python3 - "$SOCKET" <<'EOF'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(b'{"jsonrpc":"2.0","id":99,"method":"pane.snapshot","params":{"session":"s014","pane_id":"pane-1"}}\n')
s.recv(1)
s.close()
EOF

wait_for_contained_failures 1
kill -0 "$DAEMON_PID"

# An oversized request line is rejected per-connection, not fatally.
python3 - "$SOCKET" <<'EOF'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
try:
    s.sendall(b"z" * (5 * 1024 * 1024) + b"\n")
    s.recv(1)
except OSError:
    pass
s.close()
EOF

wait_for_contained_failures 2
kill -0 "$DAEMON_PID"

RECHECK_JSON="$(MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" pane snapshot "$PANE_ID" --json)"
printf '%s\n' "$RECHECK_JSON" | jq -e '.ok == true' >/dev/null

MINIMUX_STATE_DIR="$STATE_DIR" "$BIN" terminate s014 --json >/dev/null

printf 's014 control-plane robustness holdout PASS\n'
