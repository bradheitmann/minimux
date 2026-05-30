# Release Gates

`scripts/validate-release.sh` is the release gate command for v0.1.0. It runs
the build, tests, fuzz smoke, holdout scripts, security scans, scope scans, and
release checklist checks, then writes command logs under
`.edge-agentic/local/evidence/release-validation/`.

```bash
scripts/validate-release.sh
zig build release-check
```

## Response Envelope

Every JSON response emitted by the `minimux` CLI uses the JSON-RPC-shaped
top-level envelope: `jsonrpc:"2.0"`, `ok`, `result` or `error`, `request_id`,
and `seq`.

Responses forwarded from the daemon control socket preserve the request id as
their `seq` value. Local CLI errors that fail before a daemon request is
sequenced use `seq:0` as an explicit sentinel. That sentinel means "no daemon
request sequence was allocated"; it is not part of the append-only session
journal sequence.

## Command Set

| Evidence class | Command | Evidence |
| -- | -- | -- |
| unit | `zig build test --summary all` | root, CLI, protocol, recovery, snapshot, transport, adapter, and observability tests |
| integration | `scripts/holdout/s002_killshot_recovery.sh` and `scripts/holdout/s008_record_tap_wait.sh` | daemon, PTY, recovery, recording, tap, and wait-idle behavior |
| protocol | `test/protocol_fixture_test.zig` through `zig build test --summary all` | public method table, fixture validation, and error code coverage |
| recovery | `test/recovery_engine_test.zig`, `test/prototype_recovery_test.zig`, and `scripts/holdout/s006_recovery_faults.sh` | atomic snapshot and degraded recovery states |
| fuzz | `zig build fuzz-transport --summary all` | encrypted frame parser rejects invalid frames without plaintext fallback |
| security | release secret scan plus `docs/SECURITY.md` checks | hardcoded credential patterns, file modes, remote transport constraints |
| holdout | `scripts/holdout/s002_killshot_recovery.sh`, `scripts/holdout/s008_record_tap_wait.sh`, `scripts/holdout/s011_docs_first_contact.sh`, `scripts/holdout/s012_concurrent_failure_isolation.sh`, `scripts/holdout/s013_repeated_observe_recovery_stress.sh` | encounter-level behavior beyond unit assertions |
| stress | `scripts/holdout/s012_concurrent_failure_isolation.sh` and `scripts/holdout/s013_repeated_observe_recovery_stress.sh` | live sessions maintain independent daemon failure boundaries; repeated pane send, snapshot, record, tap, kill, and recover cycles stay ordered and recoverable |

## CI Rejections

CI runs `scripts/validate-release.sh`. The command fails when any of these are
true:

- a required release command exits non-zero
- release command evidence logs are missing
- a stress holdout fails or lacks command evidence
- if a planning ledger is present, a completed story holdout is not marked
  `result: PASS`
- an unallowed credential-like pattern appears outside documentation or policy
  examples
- a private-organization, local-path, personal-identifier, or high-signal
  credential pattern appears in the public tree
- release scripts contain unbounded sleep calls
- implementation paths contain Module 2 scope terms
- `docs/release-gates.md` lacks a North Star problem mapping

## North Star Mapping

| Problem | Verification path | Release requirement |
| -- | -- | -- |
| P1: terminal state, scrollback, and audit trail vanish after an agent crash | `scripts/holdout/s002_killshot_recovery.sh`, `scripts/holdout/s012_concurrent_failure_isolation.sh`, `scripts/holdout/s013_repeated_observe_recovery_stress.sh`, `test/prototype_recovery_test.zig`, `test/recovery_engine_test.zig` | recovered snapshot includes `SESSION_RECOVERED`; degraded state is explicit; independent and repeated sessions recover without cross-contamination |
| P2: existing PTY layers bake in the substrate underneath them | `test/custom_pane_backend_test.zig`, adapter tests in `zig build -Dtest-filter=adapter test`, `docs/adapters.md` | baremetal and Docker placement remain descriptors; minimux does not own isolation |
| P3: orchestrators inherit human-multiplexer brittleness from tmux-shaped backends | `scripts/holdout/s008_record_tap_wait.sh`, `scripts/holdout/s011_docs_first_contact.sh`, `docs/API.md` | agents can drive JSON and snapshots without human terminal UI |

## Release Checklist

- [ ] `scripts/validate-release.sh` exits 0.
- [ ] `.edge-agentic/local/evidence/release-validation/Summary.json` exists.
- [ ] Story holdouts for completed stories are `PASS` when a planning ledger is
  present.
- [ ] `scripts/holdout/s012_concurrent_failure_isolation.sh` proves two live
  sessions can be killed and recovered independently.
- [ ] `scripts/holdout/s013_repeated_observe_recovery_stress.sh` proves
  repeated pane send, snapshot, record, tap, kill, and recover cycles.
- [ ] Secret scan failures are zero outside documented allowlist paths.
- [ ] Public hygiene scan failures are zero.
- [ ] Module 2 scope scan failures are zero outside boundary declarations.
- [ ] Release notes cite the validation evidence directory.
