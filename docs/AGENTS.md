# Agent Quickstart

This document is the shortest path for an agent that needs to drive minimux
without reading Zig internals.

## Requirements

- Zig `0.16.0` or newer.
- `bash`, `sh`, `jq`, and standard POSIX process tools.
- A writable state directory. Set `MINIMUX_STATE_DIR` explicitly for tests.

## Build Once

```bash
zig build --summary all
export MINIMUX_BIN="$PWD/zig-out/bin/minimux"
export MINIMUX_STATE_DIR="$(mktemp -d)"
```

`MINIMUX_STATE_DIR` stores session metadata, snapshots, journals, recordings,
and daemon logs. Remove the directory when the test run is no longer needed.

## First Contact Workflow

Start one managed shell:

```bash
"$MINIMUX_BIN" run --name mx-agent -- sh
```

Send input. The CLI decodes `<CR>` to a newline:

```bash
"$MINIMUX_BIN" send mx-agent "printf 'agent-ready\n'<CR>"
```

Wait for shell idle state:

```bash
"$MINIMUX_BIN" wait-idle mx-agent --timeout-ms 5000
```

Capture the session snapshot:

```bash
"$MINIMUX_BIN" snapshot mx-agent --json
```

Recover after daemon loss:

```bash
daemon_pid="$("$MINIMUX_BIN" attach mx-agent --json | jq -r '.result.session.daemon_pid')"
kill -9 "$daemon_pid"
"$MINIMUX_BIN" snapshot mx-agent --json
```

The recovered snapshot returns `result.recovery.state:"recovered"` and includes
`SESSION_RECOVERED` in `result.recovery.notifications`.

## Cleanup

Terminate a running session:

```bash
"$MINIMUX_BIN" terminate mx-agent --json
```

If a daemon has already been killed, `snapshot` can still read recovery state
from disk. Remove `MINIMUX_STATE_DIR` after evidence is captured.
