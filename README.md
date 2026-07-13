# minimux

minimux is a Zig daemon for agent-owned PTY sessions. It keeps terminal state
under the substrate you chose and beneath the orchestrator you control. The
v0.1.0 boundary is daemon substrate only: managed PTY ownership, local JSON-RPC
control, structured snapshots, recovery state, recording and tap streams,
encrypted remote transport, and adapter boundaries.

The canonical product contract is [SPEC-v2.2.md](SPEC-v2.2.md). The agent path
starts in [docs/AGENTS.md](docs/AGENTS.md).

## Install

Homebrew (macOS and Linux):

```bash
brew install bradheitmann/tap/minimux
```

npm (downloads the matching release binary and verifies its checksum):

```bash
npm install -g @bradheitmann/minimux
```

Tagged releases also publish prebuilt binaries for x86_64/aarch64 Linux and
macOS on the GitHub Releases page, packaged as tarballs with SHA-256
checksums:

```bash
tar -xzf minimux-<version>-<target>.tar.gz
install -m 0755 minimux-<version>-<target>/minimux ~/.local/bin/minimux
minimux --json system.health
```

To build from source with Zig 0.16.0:

```bash
zig build --summary all
install -m 0755 zig-out/bin/minimux ~/.local/bin/minimux   # or any PATH dir
minimux --json system.health
```

## Build

```bash
zig build --summary all
zig build test --summary all
```

The installed development binary is `zig-out/bin/minimux`.

## First Contact

This path runs a managed shell, writes input, waits for idle state, captures a
snapshot, kills the daemon process, and verifies recovered state from disk.

```bash
zig build --summary all
export MINIMUX_STATE_DIR="$(mktemp -d)"

zig-out/bin/minimux run --name mx-docs -- sh
zig-out/bin/minimux send mx-docs "printf 'minimux-docs\n'<CR>"
zig-out/bin/minimux wait-idle mx-docs --timeout-ms 5000
zig-out/bin/minimux snapshot mx-docs --json

daemon_pid="$(zig-out/bin/minimux attach mx-docs --json | jq -r '.result.session.daemon_pid')"
kill -9 "$daemon_pid"
zig-out/bin/minimux snapshot mx-docs --json
```

The final snapshot returns `result.recovery.state:"recovered"` and includes a
`SESSION_RECOVERED` notification. A runnable version of the same path is in
[examples/prototype.sh](examples/prototype.sh):

```bash
bash examples/prototype.sh --check
```

## Public Surface

The v0.1.0 method table is fixed in `src/minimux/proto.zig` and validated by
`test/spec_scope_test.zig`.

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

See [docs/API.md](docs/API.md) for parameters, return envelopes, errors,
examples, and edge cases for every method.

## Runtime Docs

- [docs/AGENTS.md](docs/AGENTS.md): first-contact workflow for an agent.
- [docs/API.md](docs/API.md): public method reference.
- [docs/RECOVERY.md](docs/RECOVERY.md): journal, snapshot, and crash recovery
  behavior.
- [docs/SECURITY.md](docs/SECURITY.md): local state, recording, and remote
  transport security boundaries.
- [docs/adapters.md](docs/adapters.md): CustomPaneBackend and substrate
  placement adapter boundaries.
- [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md): test layout, fixture corpora,
  holdout conventions, and release validation.
- [examples/README.md](examples/README.md): runnable examples.

## Boundary

In scope for v0.1.0:

- one daemon process per managed session
- daemon-owned PTY process supervision
- local JSON-RPC control socket
- local PTY input and output stream endpoint
- structured VT snapshot state
- append-only journal plus atomic snapshot recovery
- recording and tap streams
- shell-generic idle detection
- encrypted remote transport
- CustomPaneBackend-compatible adapter
- baremetal and Docker placement adapters

Out of scope for v0.1.0:

- human terminal interface
- workflow scheduling
- sandbox enforcement
- plaintext remote transport
- compatibility replacement claims against tmux, cmux, or headless-terminal

## Verification

```bash
zig build --summary all
zig build test --summary all
zig build c-smoke --summary all
zig build fuzz-transport --summary all
bash examples/prototype.sh --check
```

## License

minimux is licensed under the [Apache License, Version 2.0](LICENSE). The
Apache-2.0 patent grant is intentional: minimux is control-surface
infrastructure, and downstream orchestrators need patent safety alongside
copyright permission.
