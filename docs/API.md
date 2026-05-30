# API Reference

The public method table is defined in `src/minimux/proto.zig`. The CLI exposes
the same surface through local commands and daemon control-socket calls. Success
responses carry `ok:true`; control-socket responses also include
`jsonrpc:"2.0"`.

## Error Envelope

```json
{
  "jsonrpc": "2.0",
  "ok": false,
  "error": {
    "code": "error.DaemonNotRunning",
    "message": "invalid control request",
    "detail": "mx-agent",
    "retryable": false
  },
  "request_id": "control-socket",
  "seq": 7
}
```

Common error codes are listed in `src/minimux/proto.zig` and generated into
`include/minimux.h` during `zig build`.

## `session.create(name, options)`

- Purpose: create a named managed session and start a per-session daemon.
- Parameters: `name` string; `options` object. CLI path also accepts an argv
  after `--`.
- Return type: session result object with `session`, `daemon_pid`, `state`,
  `argv`, and recovery metadata for `run`.
- Errors: `error.MissingArgument`, `error.InvalidSessionName`,
  `error.SessionNameTooLong`, `error.ControlSocketTimeout`.
- Example:

```bash
zig-out/bin/minimux run --name mx-api -- sh
```

- Edge cases: session names are limited to 64 bytes and may contain letters,
  digits, `.`, `_`, and `-`. A daemon control socket must appear before the
  create command returns.

## `session.attach(name)`

- Purpose: inspect an existing managed session through its control socket.
- Parameters: `name` string.
- Return type: `session` object with `name`, `daemon_pid`, `daemon_alive`,
  `command_count`, `state`, `control_socket`, and `log_path`.
- Errors: `error.SessionNotFound`, `error.DaemonNotRunning`,
  `error.InvalidSessionName`.
- Example:

```bash
zig-out/bin/minimux attach mx-api --json
```

- Edge cases: a missing control socket marks a previously live session
  unavailable when the daemon process cannot be reached.

## `session.list()`

- Purpose: list sessions visible in `MINIMUX_STATE_DIR`.
- Parameters: none.
- Return type: `sessions` array of session objects.
- Errors: filesystem read errors under the state directory.
- Example:

```bash
zig-out/bin/minimux list --json
```

- Edge cases: an empty state directory returns an empty array. Invalid directory
  names under `sessions/` are ignored.

## `session.terminate(name)`

- Purpose: stop a managed session and mark its lifecycle state terminated.
- Parameters: `name` string.
- Return type: terminated `session` object.
- Errors: `error.SessionNotFound`, `error.DaemonNotRunning`,
  `error.InvalidSessionName`.
- Example:

```bash
zig-out/bin/minimux terminate mx-api --json
```

- Edge cases: a terminated session keeps its state files for later inspection.

## `pane.create(session, argv, env, cwd, size)`

- Purpose: create a pane process inside a running session.
- Parameters: `session` string; `argv` string array; `env` object; `cwd`
  string; `size` object with `cols` and `rows`. The CLI currently exposes
  `--cmd`, `--cols`, and `--rows`.
- Return type: `pane` object with `pane_id`, `session`, `local_id`, `state`,
  `command`, `dimensions`, and `input_count`.
- Errors: `error.MissingSession`, `error.SessionNotFound`,
  `error.DaemonNotRunning`, `error.InvalidPaneCommand`,
  `error.InvalidPaneDimensions`.
- Example:

```bash
zig-out/bin/minimux pane create --session mx-api --cmd sh --cols 80 --rows 24 --json
```

- Edge cases: `MX_SESSION` can supply session context when the pane reference
  omits a session prefix.

## `pane.send(pane_id, bytes)`

- Purpose: write bytes to a pane PTY, or write a command to the session shell
  when using the legacy session command path.
- Parameters: `pane_id` string; `bytes` byte sequence. The CLI decodes `<CR>`
  into newline and accepts `--stdin`.
- Return type: result object with `session`, optional `pane_id`, `exit_code`,
  `command`, `stdout`, and `stderr`.
- Errors: `error.MissingInput`, `error.PaneNotFound`, `error.PaneNotActive`,
  `error.PaneClosed`, `error.DaemonNotRunning`.
- Example:

```bash
zig-out/bin/minimux pane send mx-api:pane-1 "printf 'ready\n'<CR>" --json
```

- Edge cases: closed panes reject input. Session-level `send` trims empty input
  and returns an invalid-argument exit code.

## `pane.resize(pane_id, cols, rows)`

- Purpose: resize a live pane and its shadow VT state.
- Parameters: `pane_id` string; `cols` unsigned 16-bit integer; `rows`
  unsigned 16-bit integer.
- Return type: updated `pane` object.
- Errors: `error.InvalidPaneDimensions`, `error.PaneNotActive`,
  `error.PaneClosed`, `error.DaemonNotRunning`.
- Example:

```bash
zig-out/bin/minimux pane resize mx-api:pane-1 --cols 100 --rows 30 --json
```

- Edge cases: `cols:0` or `rows:0` is invalid.

## `pane.snapshot(pane_id)`

- Purpose: return structured VT state for one pane.
- Parameters: `pane_id` string.
- Return type: `snapshot` object with schema version, pane id, dimensions,
  cursor, sequence, visible text, visible cells, process state, recovery state,
  and VT engine metadata.
- Errors: `error.MissingPane`, `error.PaneNotFound`, `error.PaneNotActive`,
  `error.DaemonNotRunning`.
- Example:

```bash
zig-out/bin/minimux pane snapshot mx-api:pane-1 --json
```

- Edge cases: a pane must be active in the daemon runtime. State files alone are
  not enough for pane snapshots.

## `pane.close(pane_id)`

- Purpose: close a pane and stop its child process.
- Parameters: `pane_id` string.
- Return type: closed `pane` object.
- Errors: `error.MissingPane`, `error.PaneNotActive`, `error.PaneNotFound`,
  `error.DaemonNotRunning`.
- Example:

```bash
zig-out/bin/minimux pane close mx-api:pane-1 --json
```

- Edge cases: closing a pane does not terminate the parent session.

## `agent.wait_idle(pane_id, timeout_ms, harness)`

- Purpose: wait until the shell-generic harness reports idle or exited state.
- Parameters: `pane_id` string; `timeout_ms` unsigned 64-bit integer; `harness`
  object. The CLI exposes `--timeout-ms` and uses `shell-generic`.
- Return type: result object with `session`, `state`, `idle`, `timeout_ms`,
  `harness`, optional `exit_code`, and detail object.
- Errors: `error.WaitIdleTimeout`, `error.WaitIdleUnknown`,
  `error.DaemonNotRunning`.
- Example:

```bash
zig-out/bin/minimux agent wait-idle mx-api:pane-1 --timeout-ms 5000 --json
```

- Edge cases: `timeout_ms:0` returns a retryable timeout. A terminated session
  reports exited state instead of accepting more input.

## `record.start(pane_id, path, policy)`

- Purpose: start an asciicast-v2 recording for a pane.
- Parameters: `pane_id` string; `path` string; `policy` object. The CLI accepts
  `--path` and `--on-full` with `error_back`, `stop_recording`, or
  `drop_oldest`.
- Return type: result object with `recording_id`, `pane_id`, `path`, `format`,
  `disk_full_policy`, file mode, directory mode, and directory.
- Errors: `error.RecordingDiskFull`, `error.InvalidRecordingPath`,
  `error.DaemonNotRunning`.
- Example:

```bash
zig-out/bin/minimux record start mx-api:pane-1 --path "$MINIMUX_STATE_DIR/mx-api.cast" --on-full error_back --json
```

- Edge cases: recording files are created with mode `0600`; recording
  directories are set to mode `0700`. Paths containing `..` are rejected.

## `record.stop(recording_id)`

- Purpose: stop an active recording.
- Parameters: `recording_id` string. The CLI command also includes the session
  name so it can reach the daemon.
- Return type: result object with `recording_id`, `pane_id`, `path`, and
  `state:"stopped"`.
- Errors: `error.MissingRecording`, `error.RecordingNotFound`,
  `error.DaemonNotRunning`.
- Example:

```bash
zig-out/bin/minimux record stop mx-api rec-1 --json
```

- Edge cases: stopping a recording does not delete the asciicast file.

## `tap.open(pane_id, filter)`

- Purpose: open an ordered event tap for pane output.
- Parameters: `pane_id` string; `filter` object. The CLI accepts `--filter`
  as an opaque string.
- Return type: result object with `tap_id`, `pane_id`, back-pressure policy,
  and any existing events after the tap start sequence.
- Errors: `error.DaemonNotRunning`, invalid identifier errors.
- Example:

```bash
zig-out/bin/minimux tap open mx-api:pane-1 --json
```

- Edge cases: local back pressure blocks control response until the reader can
  accept the event. Remote back pressure uses a bounded queue and closes slow
  readers on overflow.

## `tap.close(tap_id)`

- Purpose: close an event tap and return events observed since it opened.
- Parameters: `tap_id` string. The CLI command also includes the session name.
- Return type: result object with `tap_id`, `pane_id`, `state:"closed"`, and
  `events`.
- Errors: `error.MissingTap`, `error.TapNotFound`, `error.DaemonNotRunning`.
- Example:

```bash
zig-out/bin/minimux tap close mx-api tap-1 --json
```

- Edge cases: closing an unknown tap returns an error and leaves other taps
  open.

## `system.health()`

- Purpose: report the local binary product, version, and prototype status.
- Parameters: none.
- Return type: object with `status`, `product`, and `version`.
- Errors: `error.UnsupportedMethod` when the `--json` wrapper names an unknown
  method.
- Example:

```bash
zig-out/bin/minimux --json system.health
```

- Edge cases: this method does not require a running session.
