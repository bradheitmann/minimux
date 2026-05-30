# Agent Instructions

This repository is the public minimux source tree. Keep changes scoped to the
daemon, protocol, docs, tests, examples, and release gates that ship here.

## Boundaries

- Do not add private planning ledgers, local agent state, generated evidence,
  market research, or machine-specific configuration.
- Do not add private organization names, personal identities, local filesystem
  paths, or private repository names.
- Prefer `SPEC-v2.2.md`, `README.md`, and `docs/*` as the public source of
  product truth.
- Keep historical/internal context out of git. Use ignored local files when
  temporary context is required.

## Verification

Run these before submitting product changes:

```bash
zig fmt --check build.zig cmd/minimux.zig src/minimux/*.zig src/minimux/adapters/*.zig src/minimux/platform/*.zig test/*.zig test/fuzz/*.zig tools/*.zig
zig build test --summary all
scripts/validate-release.sh
```

`scripts/validate-release.sh` includes build, tests, holdouts, public hygiene,
secret-pattern, and scope-drift checks.
