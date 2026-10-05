#!/usr/bin/env bash
# Mechanical verification gate for aria2-browser-shim.
#
# This is the single command an agent (or human) must run before claiming work is
# done. It is deliberately dumb: no cleverness, no partial credit, one exit code.
# Exit 0 means: the tree typechecks AND tests pass AND the extension bundles.
#
# Rationale (measured 2026-10-05, baseline):
#   `vitest run`    -> 99 passed / 5 files   (green)
#   `tsc --noEmit`  -> exit 2, 28 errors, all in tests/integration.test.ts
#   `wxt build`     -> ok, 228.9 kB
# i.e. the suite was fully green while the typecheck was red. Running only the
# tests would have reported success on a tree that does not compile cleanly.
# Any "done" claim must therefore clear all three gates, not just the tests.
#
# Usage:  bash scripts/verify.sh            # full gate
#         bash scripts/verify.sh --quick    # skip the bundle step
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

FAILED=()
run_step() {
  local name="$1"; shift
  echo ""
  echo "── ${name} ────────────────────────────────────────────────"
  if "$@"; then
    echo "PASS: ${name}"
  else
    local code=$?
    echo "FAIL: ${name}  (exit ${code})"
    FAILED+=("${name}")
  fi
}

# 1. Harness integrity. A SKILL.md whose YAML frontmatter is malformed is SILENTLY
#    dropped from the agent's skill catalog — no error, the skill just never loads.
#    That is exactly the kind of quiet failure this script exists to catch.
run_step "skill frontmatter" bash -c '
  rc=0
  for f in .agents/skills/*/SKILL.md; do
    [[ -e "$f" ]] || continue
    name=$(sed -n "s/^name: *//p" "$f" | head -1)
    desc=$(sed -n "s/^description: *//p" "$f" | head -1)
    if [[ -z "$name" || ${#desc} -lt 20 ]]; then
      echo "malformed frontmatter (name and a descriptive description are required): $f" >&2
      rc=1
    fi
  done
  exit $rc'

# 2. Typecheck. `tsc --noEmit` over the WXT-generated project scope, which
#    includes tests/ (the only exclusions are .output and node_modules).
run_step "typecheck (tsc --noEmit)" npx tsc --noEmit

# 3. Unit + integration tests.
run_step "vitest" npx vitest run

# 4. The artifact must actually build.
if [[ $QUICK -eq 0 ]]; then
  run_step "wxt build" npx wxt build
fi

echo ""
echo "════════════════════════════════════════════════════════════"
if [[ ${#FAILED[@]} -eq 0 ]]; then
  echo "VERIFY OK — all steps passed"
  exit 0
fi
echo "VERIFY FAILED — ${#FAILED[@]} step(s): ${FAILED[*]}"
exit 1
