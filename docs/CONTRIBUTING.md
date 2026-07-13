# Contributing: Test Layout and Release Validation

This document maps the test surface and the release gate so a contributor or
agent can add coverage in the right place and validate a change the same way
CI does. Product boundaries live in `SPEC-v2.2.md`; contribution boundaries
live in `AGENTS.md`.

## Source Layout

```
cmd/minimux.zig            CLI entry point and daemon subcommand bridge
src/minimux/               daemon, session, pty, journal, snapshot, recovery,
                           observe (record/tap), shadow (VT engine), crypto,
                           transport, proto (method table), harness_shell
src/minimux/platform/      darwin and linux platform code
src/minimux/adapters/      custom_pane_backend, substrate, baremetal, docker
include/minimux.h          generated C header (regenerate: zig build gen-c-header)
tools/gen-c-header.zig     header generator
test/                      out-of-module test suites and fixtures
scripts/holdout/           black-box holdout scripts (release-gated)
scripts/validate-release.sh  the release gate
packaging/npm/             npm wrapper that installs release binaries
examples/                  runnable first-contact and client examples
```

## Test Taxonomy

Four layers, in increasing distance from the code:

1. **Inline module tests** live next to the implementation in
   `src/minimux/*.zig` and run as the root-module test batch.
2. **Suite tests** live in `test/*.zig`, one file per concern:

   | File | Covers |
   | -- | -- |
   | `spec_scope_test.zig` | the frozen v0.1.0 public method table |
   | `cli_envelope_test.zig` | JSON-RPC-shaped CLI response envelope |
   | `protocol_fixture_test.zig` | protocol fixture corpus validation |
   | `snapshot_fixture_test.zig` | VT fixture corpus validation |
   | `session_lifecycle_test.zig` | session create/attach/list/terminate |
   | `pty_lifecycle_test.zig` | PTY ownership and child supervision |
   | `prototype_recovery_test.zig` | kill-shot recovery path |
   | `recovery_engine_test.zig` | degraded recovery state machine |
   | `observe_test.zig` | recording and tap streams |
   | `transport_test.zig` | encrypted frame codec |
   | `custom_pane_backend_test.zig` | CustomPaneBackend adapter |

3. **Fuzz** target: `test/fuzz/transport_frame_fuzz.zig`, run via
   `zig build fuzz-transport --summary all`.
4. **Holdouts**: `scripts/holdout/*.sh` drive the built binary end to end
   (spawn real daemons, kill them, verify recovery). They encode
   encounter-level behavior that unit assertions cannot.

Run everything:

```bash
zig build test --summary all
zig build test -Dtest-filter=adapter --summary all   # name-substring filter
```

## Fixture Corpora

### VT fixtures (`test/fixtures/vt/`)

Each scenario is an `.ansi`/`.json` pair. The `.ansi` file holds the raw byte
stream for reference; the `.json` file is the executable fixture consumed by
`snapshot.validateFixture`, which feeds `chunks` (JSON-escaped, e.g. `\u001b`
for ESC) into the VT engine, applies `resizes`, then asserts `visible_text`,
`cursor`, `sequence_min`, `alternate_screen`, and per-cell `text`/`attrs`
expectations, and finally checks the rendered snapshot JSON contract fields.

To add one: create the pair, hand-compute expectations from
`src/minimux/shadow.zig` semantics, then register both an `@embedFile` and a
test block in `test/snapshot_fixture_test.zig`.

### Protocol fixtures (`test/fixtures/protocol/`)

`valid-v0.1.0.json` plus one `invalid-*.json` per rejection class (unknown
method, missing required param, enum violation, unknown required field,
non-monotonic sequence). `protocol_fixture_test.zig` asserts the valid corpus
parses and every invalid corpus fails with the intended error.

## Holdout Scripts

| Script | Proves |
| -- | -- |
| `s002_killshot_recovery.sh` | daemon kill → recovered snapshot + `SESSION_RECOVERED` |
| `s006_recovery_faults.sh` | corrupt snapshot / partial journal → explicit degraded states |
| `s008_record_tap_wait.sh` | record, tap, and wait-idle behavior |
| `s011_docs_first_contact.sh` | README first-contact path works from docs alone |
| `s012_concurrent_failure_isolation.sh` | two live sessions fail and recover independently |
| `s013_repeated_observe_recovery_stress.sh` | repeated send/snapshot/record/tap/kill/recover cycles |
| `s014_control_plane_robustness.sh` | oversized requests and client disconnects cannot kill the daemon |

Conventions for a new holdout: bash with `set -euo pipefail`, no unbounded
`sleep` (the gate scans for it), exit code is the verdict. Wire it into
`scripts/validate-release.sh` twice: a `run_gate holdout-sNNN ...` line and
the required-evidence list in `check_release_evidence`.

## Release Validation

```bash
scripts/validate-release.sh
```

CI runs exactly this on ubuntu and macos for every push and pull request
(`.github/workflows/ci.yml`). It executes build, test, `c-smoke`,
`fuzz-transport`, all holdouts, and the docs prototype, writing per-command
logs under `.edge-agentic/local/evidence/release-validation/`, then applies
static checks. It fails when:

- any release command exits non-zero, or its evidence log is missing
- a credential-like pattern appears outside the documented allowlist
- a private-organization, personal-identifier, local-path, or high-signal
  credential pattern appears in the public tree
- implementation paths contain Module 2 scope terms (see `SPEC-v2.2.md`
  non-goals)
- release scripts contain unbounded sleeps
- `docs/release-gates.md` loses its P1/P2/P3 problem mapping or an evidence
  class

Before submitting, also run the formatting gate from `AGENTS.md`:

```bash
zig fmt --check build.zig cmd/minimux.zig src/minimux/*.zig \
  src/minimux/adapters/*.zig src/minimux/platform/*.zig test/*.zig \
  test/fuzz/*.zig tools/*.zig
```

The public-hygiene checks are a contribution rule, not just a scan: keep
personal identities, machine paths, private planning, and generated evidence
out of the tree. `docs/release-gates.md` documents the full gate contract.
