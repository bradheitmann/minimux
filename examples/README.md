# Examples

`prototype.sh` is the checked first-contact path used by the documentation
slice.

```bash
bash examples/prototype.sh --check
```

The script:

- builds `zig-out/bin/minimux` when the binary is missing
- creates an isolated `MINIMUX_STATE_DIR`
- starts a managed shell with `run`
- sends input with `send`
- waits with `wait-idle`
- snapshots live state
- kills the daemon process
- snapshots recovered state

Set `MINIMUX_BIN` to test a different binary:

```bash
MINIMUX_BIN=/path/to/minimux bash examples/prototype.sh --check
```

The script exits non-zero when any JSON field does not match the documented
path.

## Orchestrator client

`orchestrator-client.mjs` is the orchestrator-seat path: a zero-dependency
Node script that drives minimux the way a scheduler or harness manager would.

```bash
zig build --summary all
node examples/orchestrator-client.mjs
```

The script:

- creates a managed session with `run`
- spawns a pane from exact `argv` with a replaced `env` and a `cwd`
- waits for pane output quiescence with `agent wait-idle`
- reads the pane state from `pane snapshot` without scraping
- runs a session-shell command and waits for the queue to drain
- closes the pane, kills the daemon with SIGKILL, and verifies the recovered
  session snapshot still contains the executed command output

Every step asserts the documented JSON contract and the script exits non-zero
on the first mismatch.
