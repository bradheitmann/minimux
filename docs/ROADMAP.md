# Roadmap

This public roadmap records current product state and forward direction. It is
not the private engineering ledger.

## Current State

minimux v0.1.0 is scoped as a daemon substrate for agent-owned PTY sessions:

- per-session daemon process
- daemon-owned PTY supervision
- local JSON-RPC control
- local stream endpoint for PTY input and output
- structured VT snapshots
- append-only journal and atomic snapshot recovery
- recording and tap streams
- shell-generic idle detection
- encrypted transport framing
- CustomPaneBackend, baremetal, and Docker adapter boundaries

The release gate is `scripts/validate-release.sh`. It runs build, tests,
holdouts, public hygiene checks, secret-pattern checks, and scope-drift checks.
The holdout set includes concurrent daemon failure isolation for two live
sessions and repeated observe/recovery stress cycles.

## Before The v0.1.0 Tag

- Keep GitHub Actions green on macOS and Linux.
- Decide and add the project license.
- Add release notes that cite the validation command and platform matrix.
- Add install/package instructions once the binary distribution path is chosen.
- Keep the public repository free of private planning, local paths, personal
  identifiers, and private research artifacts.

## After v0.1.0

- Expand VT fixture coverage and cross-platform soak tests.
- Expand repeated run, send, snapshot, record, tap, kill, and recover stress
  runs beyond the release-gate smoke length.
- Harden remote transport with end-to-end integration tests beyond parser fuzz.
- Publish adapter examples for CustomPaneBackend and substrate placement.
- Improve contributor docs around test layout and release validation.

## Explicitly Out Of Scope

- Human terminal UI.
- Workflow scheduling.
- Sandbox enforcement.
- Plaintext remote transport.
- Compatibility replacement claims against human multiplexers.
