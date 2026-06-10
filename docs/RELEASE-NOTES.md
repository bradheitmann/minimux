# Release Notes

## v0.1.1

Control-plane robustness patch. Both fixes came out of driving a real
interactive workload (npm's browser-auth publish flow) inside minimux panes.

- The daemon now contains per-request failures. A client that disconnects
  mid-response, sends malformed JSON, or overflows the request cap costs
  itself that response; previously the error escaped the control loop,
  killed the daemon, and took its panes down with it. Failures are logged
  to the session `daemon.log`.
- Control framing is growable instead of buffer-bound. Large pane
  snapshots (a filled 220x50 pane is ~1 MB of JSON) no longer fail the CLI
  with `StreamTooLong` at 64 KB, and `pane.send --stdin` payloads no longer
  overflow the daemon's 8 KB request buffer. Caps: 4 MB per request, 64 MB
  per response.
- New holdout `scripts/holdout/s014_control_plane_robustness.sh` pins both
  behaviors and runs in the release gate and CI.

Validation and platform matrix are unchanged from v0.1.0 below.

## v0.1.0 (2026-06-10)

minimux v0.1.0 is the daemon substrate for agent-owned PTY sessions: one
daemon per managed session, daemon-owned PTY supervision, a local JSON-RPC
control socket, structured VT snapshots, append-only journal plus atomic
snapshot recovery, recording and tap streams, shell-generic idle detection,
encrypted remote transport framing, and CustomPaneBackend, baremetal, and
Docker adapter boundaries.

### Validation

Every release candidate must pass the full release gate:

```bash
scripts/validate-release.sh
```

The gate runs the build, unit tests, transport-frame fuzz smoke, the holdout
scripts (kill-shot recovery, recovery faults, record/tap/wait, docs-first
contact, concurrent failure isolation, repeated observe/recovery stress),
secret-pattern scans, public-hygiene scans, and scope-drift scans. Command
logs are written to `.edge-agentic/local/evidence/release-validation/` and
the run fails when any required evidence log is missing.

### Platform matrix

| Platform | Toolchain | Verification |
| -- | -- | -- |
| macOS (Apple Silicon) | Zig 0.16.0 | CI `macos-latest` runs `scripts/validate-release.sh` |
| Linux (x86_64) | Zig 0.16.0 | CI `ubuntu-latest` runs `scripts/validate-release.sh` |

### Highlights since the initial public release

- Apache-2.0 license adopted; copyright held by the minimux authors.
- `agent.wait_idle` now waits: the session shell drains its queued command
  channel before reporting idle, panes report idle after a 150 ms
  output-quiet window, and deadline expiry returns the typed retryable
  `error.WaitIdleTimeout`.
- `pane.create` honors the spec surface: `argv` spawns directly, `env`
  replaces the child environment, `cwd` and `size:{cols,rows}` apply at
  spawn. The legacy `command` string still runs through `sh -lc`.
- The daemon control loop pumps background pane output every tick, so
  snapshots, taps, and recordings stay current without a `pane.send`.
- The shadow VT engine handles erase-line (CSI K), relative cursor moves
  (CSI A/B/C/D), and backspace.
- `examples/orchestrator-client.mjs` proves the orchestrator-seat contract
  end to end, including crash recovery.

### Known limitations

- The control loop is single-threaded; a pane `wait_idle` can hold the
  control socket for up to its timeout budget.
- Session-shell `pane.send` is sentinel-based and synchronous; it is a
  command/response surface, not a byte stream.
- The shadow VT engine is an ASCII subset standing in for the planned
  libghostty-vt port: no UTF-8 cells, no 256-color/truecolor, scrollback
  counters without stored content.
- The shell-generic harness cannot distinguish a silently busy command from
  an idle prompt; pair `agent.wait_idle` with `pane.snapshot`.
- Remote transport is validated by parser fuzzing and unit tests; end-to-end
  remote integration hardening is tracked in the roadmap.
