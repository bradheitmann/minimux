# minimux v2.2 Focused Specification

**Status:** Canonical pre-engineering target
**Authoring agent:** Miyagi
**Generated:** 2026-05-28T00:00:00Z
**Scope:** v0.1.0 daemon substrate, kill-shot prototype, and build plan

## Decision Filter

minimux keeps the terminal intact across agent crashes inside the substrate the operator chose and beneath the orchestrator the operator controls. It is never the substrate, never the orchestrator, and never a multiplexer for humans.

## Product

minimux is a Zig daemon that owns PTYs for AI agents, persists terminal state across daemon and child-process failure boundaries, and exposes local or remote machine-readable control surfaces for orchestrators and tools.

## v2.2 Correction from v2.1

v2.1 described two modules: a primitive and an optional UI/middleware layer. v2.2 removes the UI/middleware layer from v0.1.0. The focused v0.1.0 product is:

- per-session daemon process
- managed PTY ownership
- local JSON-RPC control socket
- local stream endpoint for PTY input and output
- structured VT snapshot powered by libghostty-vt
- append-only journal and atomic snapshot recovery
- recording and tap streams
- shell-generic wait-idle harness
- encrypted remote transport
- CustomPaneBackend adapter
- baremetal and Docker substrate placement adapters
- agent-facing documentation and release verification gates

## Explicit Non-Goals

- No minimux-ui module, tab bar, split layout, theme runtime, compositor, browser pane, layout engine, or human terminal UX in v0.1.0.
- No human multiplexer code path.
- No workflow scheduler, retry engine, task allocator, or durable orchestration engine.
- No microVM, container runtime, sandbox enforcement engine, or confidential-computing primitive.
- No claim of tmux compatibility or bare-PTY latency parity.
- No optional plaintext remote transport.

## Prototype Bounds

The prototype is the two-week kill-shot path. It exists to prove or disprove the core recovery claim before the full v0.1.0 build proceeds.

### In Prototype

- `minimux run --name x -- bash` creates one managed local session.
- `minimux send x "echo hi<CR>"` writes input to the daemon-owned PTY.
- `minimux wait-idle x --timeout-ms 5000` returns when the shell prompt is observed or returns a typed timeout.
- `minimux snapshot x --json` returns dimensions, cursor, visible text, scrollback excerpt, process state, and recovery state.
- Killing the daemon and restarting it returns a recovered snapshot with a SESSION_RECOVERED notification and dead child-process status.

### Outside Prototype but Inside v0.1.0

- multiple panes per session
- remote encrypted transport
- CustomPaneBackend adapter
- Docker placement adapter
- full protocol fuzzing
- release documentation set

## Architecture

The architecture follows a hexagonal boundary. The domain core is session, pane, journal, snapshot, recording, tap, and recovery state. Ports are PTY driver, VT state engine, journal store, snapshot store, transport, clock, filesystem, and process supervisor. Adapters implement POSIX PTY, libghostty-vt, local filesystem, Unix socket JSON-RPC, TCP AEAD transport, CLI, CustomPaneBackend, baremetal placement, and Docker placement.

Dependency direction is:

```
cmd/minimux -> src/minimux application services -> src/minimux domain -> platform adapters
```

The domain layer must not depend on CLI parsing, JSON serialization details, libghostty-vt concrete types, operating-system calls, or filesystem paths.

## Required Public Methods

- `session.create(name, options)`
- `session.attach(name)`
- `session.list()`
- `session.terminate(name)`
- `pane.create(session, argv, env, cwd, size)`
- `pane.send(pane_id, bytes)`
- `pane.resize(pane_id, cols, rows)`
- `pane.snapshot(pane_id)`
- `pane.close(pane_id)`
- `agent.wait_idle(pane_id, timeout_ms, harness)`
- `record.start(pane_id, path, policy)`
- `record.stop(recording_id)`
- `tap.open(pane_id, filter)`
- `tap.close(tap_id)`
- `system.health()`

## Data Guarantees

- Journal entries are append-only NDJSON with monotonically increasing sequence numbers.
- Snapshots are written through temp file plus fsync plus atomic rename.
- Recovery never reports clean success after corruption; degraded state is explicit.
- Recording files use mode 0600 and recording directories use mode 0700.
- Remote control and PTY streams are encrypted with ChaCha20-Poly1305 and replay-protected sequence numbers.

## Success Criteria

- [ ] The kill-shot prototype passes on macOS and Linux.
- [ ] Two concurrent sessions survive independent daemon failure boundaries.
- [ ] Structured snapshots cover plain output, color attributes, alternate screen behavior, resize, process exit, and recovered state.
- [ ] Release validation rejects scope drift into Module 2, skipped holdouts, plaintext remote transport, hardcoded secrets, and missing evidence bundles.
- [ ] A fresh agent can drive the first-contact workflow from docs alone.
