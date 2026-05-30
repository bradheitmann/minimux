# Security Boundary

minimux protects its own daemon, state files, recordings, and remote transport.
It does not enforce the substrate boundary around the agent process.

## Local State

- `MINIMUX_STATE_DIR` controls where prototype state is written.
- Session names are path-safe: letters, digits, `.`, `_`, and `-`, with a
  64-byte limit.
- Control sockets live under `/tmp` and are derived from state directory plus
  session name.
- Recording files are created with mode `0600`.
- Recording directories are created or corrected to mode `0700`.

## Remote Transport

The encrypted transport code uses:

- ChaCha20-Poly1305 for frame encryption and authentication.
- HKDF-SHA256 for per-direction key derivation.
- A 64-bit connection identity.
- Sequence numbers for replay and skip detection.
- No plaintext remote fallback.

Run:

```bash
zig-out/bin/minimux transport self-test --json
```

Expected boolean fields:

```json
{
  "request_tunneled": true,
  "response_tunneled": true,
  "wrong_psk_failed": true,
  "replay_failed": true,
  "truncated_frame_failed": true,
  "sequence_skip_failed": true,
  "no_plaintext_fallback": true
}
```

## Non-Goals

The v0.1.0 boundary excludes:

- workflow scheduling
- retry engines
- task allocation
- sandbox enforcement
- container runtime ownership
- human terminal UI
- plaintext remote transport
- tmux, cmux, or headless-terminal compatibility replacement claims

Use Docker, a microVM, SSH, or another substrate when the agent process needs
isolation. Use an orchestrator when work needs scheduling, retry policy, or
durable task state.

## Evidence Commands

```bash
zig build test --summary all
zig build fuzz-transport --summary all
rg -n "(api[_-]?key|secret|token|password)\\s*[:=]" src docs examples README.md SPEC-v2.2.md
```

The secret scan is a pattern check. Review any match before treating it as a
credential.
