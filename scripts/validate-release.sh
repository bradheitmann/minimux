#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="${MINIMUX_RELEASE_EVIDENCE_DIR:-$ROOT/.edge-agentic/local/evidence/release-validation}"

cd "$ROOT"
rm -rf "$EVIDENCE_DIR"
mkdir -p "$EVIDENCE_DIR/commands" "$EVIDENCE_DIR/checks"

need_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'error.MissingTool: %s is required\n' "$1" >&2
    exit 2
  fi
}

run_gate() {
  local name="$1"
  shift
  local log="$EVIDENCE_DIR/commands/$name.log"
  printf 'RUN %s\n' "$name"
  if "$@" >"$log" 2>&1; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s; see %s\n' "$name" "$log" >&2
    sed -n '1,200p' "$log" >&2 || true
    return 1
  fi
  test -f "$log"
}

secret_match_allowed() {
  local file_path="$1"
  local line="$2"
  case "$line" in
    *'"task-state stores"'*) return 0 ;;
    *'disk-full policy is stop_recording'*) return 0 ;;
    *'disk-full policy error_back'*) return 0 ;;
  esac
  case "$file_path" in
    AGENTS.md|SPEC-v2.2.md) return 0 ;;
    docs/*) return 0 ;;
    scripts/validate-release.sh) return 0 ;;
  esac
  return 1
}

check_secret_scan() {
  local raw="$EVIDENCE_DIR/checks/secret-scan.raw.log"
  local failures="$EVIDENCE_DIR/checks/secret-scan.failures.log"
  : >"$failures"
  rg -n --hidden -i \
    --glob '!.git/**' \
    --glob '!.edge-agentic/**' \
    --glob '!.zig-cache/**' \
    --glob '!zig-cache/**' \
    --glob '!zig-out/**' \
    "(api[_-]?key|secret|password|BEGIN .*PRIVATE KEY|sk-[A-Za-z0-9])" . >"$raw" || true
  while IFS= read -r line; do
    local file_path="${line%%:*}"
    file_path="${file_path#./}"
    if ! secret_match_allowed "$file_path" "$line"; then
      printf '%s\n' "$line" >>"$failures"
    fi
  done <"$raw"
  if [ -s "$failures" ]; then
    printf 'error.SecretScan: unallowed secret-like matches; see %s\n' "$failures" >&2
    return 1
  fi
  printf 'PASS secret scan allowlist\n' >"$EVIDENCE_DIR/checks/secret-scan.log"
}

check_planning_holdouts() {
  local log="$EVIDENCE_DIR/checks/planning-holdouts.log"
  local found=0
  : >"$log"
  for story_file in project/planning/stories/STORY-MINIMUX-*.md; do
    [ -e "$story_file" ] || continue
    found=1
    local status
    status="$(awk -F': ' '/^status:/ { print $2; exit }' "$story_file")"
    if [ "$status" != "DONE" ] && [ "$status" != "COMPLETE" ]; then
      continue
    fi
    local holdout_file
    holdout_file="$(awk -F': ' '/^holdout_file:/ { print $2; exit }' "$story_file")"
    if ! rg -q '^result: PASS$' "$holdout_file"; then
      printf 'holdout_not_passed %s %s\n' "$story_file" "$holdout_file" >>"$log"
    fi
  done
  if [ "$found" -eq 0 ]; then
    printf 'SKIP no tracked planning story ledger\n' >"$log"
    return 0
  fi
  if [ -s "$log" ]; then
    printf 'error.HoldoutStatus: completed stories require PASS holdouts; see %s\n' "$log" >&2
    return 1
  fi
  printf 'PASS completed-story holdout status\n' >"$log"
}

check_public_hygiene() {
  local org_log="$EVIDENCE_DIR/checks/public-hygiene-private-org.log"
  local pii_log="$EVIDENCE_DIR/checks/public-hygiene-pii.log"
  local secret_log="$EVIDENCE_DIR/checks/public-hygiene-secrets.log"

  if rg -n -i --hidden \
    --glob '!.git/**' \
    --glob '!.edge-agentic/**' \
    --glob '!.zig-cache/**' \
    --glob '!zig-cache/**' \
    --glob '!zig-out/**' \
    'o[k]oa' . >"$org_log"; then
    printf 'error.PublicHygiene: private organization reference found; see %s\n' "$org_log" >&2
    return 1
  fi

  if rg -n -I --hidden \
    --glob '!.git/**' \
    --glob '!.edge-agentic/**' \
    --glob '!.zig-cache/**' \
    --glob '!zig-cache/**' \
    --glob '!zig-out/**' \
    '/U[s]ers/|b[r]adleyheitmann|b[r]adheitmann|B[r]ad Heitmann|B[r]ad |b[r]ad@|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' . >"$pii_log"; then
    printf 'error.PublicHygiene: personal or local path reference found; see %s\n' "$pii_log" >&2
    return 1
  fi

  if rg -n -I --hidden \
    --glob '!.git/**' \
    --glob '!.edge-agentic/**' \
    --glob '!.zig-cache/**' \
    --glob '!zig-cache/**' \
    --glob '!zig-out/**' \
    '(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' . >"$secret_log"; then
    printf 'error.PublicHygiene: high-signal credential pattern found; see %s\n' "$secret_log" >&2
    return 1
  fi

  printf 'PASS public hygiene scan\n' >"$EVIDENCE_DIR/checks/public-hygiene.log"
}

check_scope_drift() {
  local log="$EVIDENCE_DIR/checks/scope-drift.log"
  if rg -n -i "minimux-ui|tab bar|split layout|theme runtime|compositor|browser pane|layout engine|workflow scheduler|retry engine|task allocator|sandbox enforcement|plaintext remote transport" \
    cmd src test scripts .github \
    --glob '!src/minimux/root.zig' \
    --glob '!src/minimux/adapters/substrate.zig' \
    --glob '!test/spec_scope_test.zig' \
    --glob '!scripts/generate-minimux-v22-preeng.mjs' \
    --glob '!scripts/validate-release.sh' >"$log"; then
    printf 'error.ScopeDrift: Module 2 terms found in implementation paths; see %s\n' "$log" >&2
    return 1
  fi
  printf 'PASS Module 2 scope drift scan\n' >"$log"
}

check_sleep_discipline() {
  local log="$EVIDENCE_DIR/checks/non-deterministic-sleeps.log"
  if rg -n '\bsleep\s+\$|\bsleep\s+\$\{|\bsleep\s+[0-9]+$' scripts .github >"$log"; then
    printf 'error.NonDeterministicSleep: unbounded sleep found; see %s\n' "$log" >&2
    return 1
  fi
  printf 'PASS sleep discipline scan\n' >"$log"
}

check_release_checklist() {
  local log="$EVIDENCE_DIR/checks/release-checklist.log"
  : >"$log"
  for problem in P1 P2 P3; do
    if ! rg -q "$problem" docs/release-gates.md; then
      printf 'missing_problem_mapping %s\n' "$problem" >>"$log"
    fi
  done
  for evidence_class in unit integration protocol recovery fuzz security holdout stress; do
    if ! rg -q "$evidence_class" docs/release-gates.md; then
      printf 'missing_evidence_class %s\n' "$evidence_class" >>"$log"
    fi
  done
  if [ -s "$log" ]; then
    printf 'error.ReleaseChecklist: release-gates mapping incomplete; see %s\n' "$log" >&2
    return 1
  fi
  printf 'PASS release checklist mapping\n' >"$log"
}

check_release_evidence() {
  local log="$EVIDENCE_DIR/checks/release-evidence.log"
  : >"$log"
  for required in build test c-smoke fuzz-transport holdout-s002 holdout-s006 holdout-s008 holdout-s011 holdout-s012 holdout-s013 docs-prototype; do
    if [ ! -f "$EVIDENCE_DIR/commands/$required.log" ]; then
      printf 'missing_command_evidence %s\n' "$required" >>"$log"
    fi
  done
  if [ -s "$log" ]; then
    printf 'error.MissingEvidence: release command evidence missing; see %s\n' "$log" >&2
    return 1
  fi
  printf 'PASS release command evidence bundle\n' >"$log"
}

need_tool zig
need_tool jq
need_tool rg
need_tool git

run_gate build zig build --summary all
run_gate test zig build test --summary all
run_gate c-smoke zig build c-smoke --summary all
run_gate fuzz-transport zig build fuzz-transport --summary all
run_gate holdout-s002 bash scripts/holdout/s002_killshot_recovery.sh
run_gate holdout-s006 sh scripts/holdout/s006_recovery_faults.sh
run_gate holdout-s008 bash scripts/holdout/s008_record_tap_wait.sh
run_gate holdout-s011 bash scripts/holdout/s011_docs_first_contact.sh
run_gate holdout-s012 bash scripts/holdout/s012_concurrent_failure_isolation.sh
run_gate holdout-s013 bash scripts/holdout/s013_repeated_observe_recovery_stress.sh
run_gate docs-prototype bash examples/prototype.sh --check

check_secret_scan
check_public_hygiene
check_planning_holdouts
check_scope_drift
check_sleep_discipline
check_release_checklist
check_release_evidence

jq -n \
  --arg evidence_dir "$EVIDENCE_DIR" \
  '{ ok: true, evidence_dir: $evidence_dir, commands: 11, checks: 7 }' \
  | tee "$EVIDENCE_DIR/Summary.json"
