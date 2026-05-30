# Recovery

minimux recovery uses append-only journal entries plus atomic snapshot writes.
The prototype path stores state under `MINIMUX_STATE_DIR`.

## State Layout

For a session named `mx-agent`, the prototype writes:

```text
$MINIMUX_STATE_DIR/
  sessions/
    mx-agent/
      daemon.pid
      daemon.log
      visible.txt
      commands.count
      recovery.state
      lifecycle.state
      journal.ndjson
      snapshot.json
      control.path
      results/
      panes/
```

The control socket path is derived from the state directory and session name.
It is removed when the daemon is not alive.

## Write Path

1. The daemon appends command output to the journal.
2. The daemon updates visible text and command count.
3. The snapshot store writes through a temporary file, fsyncs, and renames into
   place.
4. `snapshot --json` reads live state when the daemon is alive.
5. `snapshot --json` runs recovery when the daemon is dead.

## Recovery Path

Run the checked example:

```bash
bash examples/prototype.sh --check
```

The script kills the daemon process and calls:

```bash
zig-out/bin/minimux snapshot mx-docs --json
```

Expected recovery fields:

```json
{
  "recovery": {
    "state": "recovered",
    "notifications": ["SESSION_RECOVERED"]
  },
  "process": {
    "daemon_alive": false,
    "child_status": "dead"
  }
}
```

## Degraded States

The recovery state is explicit. The current enum is defined in
`src/minimux/domain.zig`:

- `clean`
- `recovered`
- `degraded_corrupt_snapshot`
- `degraded_partial_journal`
- `degraded_missing_recording_fallback`

The daemon does not report clean success after corruption. A caller should treat
any `degraded_*` state as usable for inspection and not as proof that the
previous terminal state was byte-identical.

## Operator Notes

- Capture the snapshot before deleting `MINIMUX_STATE_DIR`.
- Keep `daemon.log`, `journal.ndjson`, and `snapshot.json` with evidence when a
  recovery claim matters.
- If the daemon is alive but the control socket is missing, `list --json` marks
  the session `unavailable`.
- Recovery is scoped to minimux state files. It does not restart a killed child
  process or recreate an external orchestrator task.
