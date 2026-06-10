# Roadmap

This public roadmap records current product state and forward direction. It is
not the private engineering ledger.

## Current State

minimux v0.1.0 is scoped as a daemon substrate for agent-owned PTY sessions:

- per-session daemon process
- daemon-owned PTY supervision
- local JSON-RPC control
- local stream endpoint for PTY input and output
- structured VT snapshots with continuous background pane capture
- append-only journal and atomic snapshot recovery
- recording and tap streams
- shell-generic idle detection with bounded waits and typed timeouts
- spec-shaped pane spawning (argv, env, cwd, size)
- encrypted transport framing
- CustomPaneBackend, baremetal, and Docker adapter boundaries

The release gate is `scripts/validate-release.sh`. It runs build, tests,
holdouts, public hygiene checks, secret-pattern checks, and scope-drift checks.
The holdout set includes concurrent daemon failure isolation for two live
sessions and repeated observe/recovery stress cycles.

## Before The v0.1.0 Tag

- [x] Decide and add the project license (Apache-2.0).
- [x] Add release notes that cite the validation command and platform matrix
  (`docs/RELEASE-NOTES.md`).
- [x] Document build-from-source install steps.
- [x] Publish an orchestrator-seat example (`examples/orchestrator-client.mjs`).
- [ ] Keep GitHub Actions green on macOS and Linux.
- [ ] Choose the binary distribution path and add packaged install
  instructions.
- [ ] Keep the public repository free of private planning, local paths,
  personal identifiers, and private research artifacts.

## After v0.1.0

- Port libghostty-vt to replace the shadow VT substitution engine: UTF-8
  cells, 256-color/truecolor attributes, stored scrollback content, and the
  full CSI/OSC surface needed to observe full-screen TUIs.
- Redesign session-shell `pane.send` from the blocking sentinel
  command/response harness toward a streaming write path with asynchronous
  result delivery, so long-running commands do not hold the control loop.
- Move the control loop off single-threaded polling so one pane wait cannot
  delay other control clients.
- Harden remote transport with end-to-end integration tests beyond parser
  fuzz.
- Expand VT fixture coverage (including the new erase-line and cursor-move
  handlers) and cross-platform soak tests.
- Expand repeated run, send, snapshot, record, tap, kill, and recover stress
  runs beyond the release-gate smoke length.
- Publish adapter examples for CustomPaneBackend and substrate placement, and
  a reference adapter for downstream harness managers that drive coding
  agents over tmux today.
- Improve contributor docs around test layout and release validation.

## Explicitly Out Of Scope

- Human terminal UI.
- Workflow scheduling.
- Sandbox enforcement.
- Plaintext remote transport.
- Compatibility replacement claims against human multiplexers.
