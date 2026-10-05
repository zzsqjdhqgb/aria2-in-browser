#!/usr/bin/env bash
# session-start.sh — orient, verify the baseline, reconcile state.
#
# Copy into your project as `scripts/session-start.sh` and adjust the
# gate command + state path. Run it as the FIRST action of every session.
#
# Exit 0 = baseline green, safe to start new work.
# Exit 1 = baseline RED, do not add features until resolved.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

GATE="${GATE_COMMAND:-bash scripts/verify.sh}"
STATE="${STATE_FILE:-docs/harness/STATE.json}"

echo "── orient ─────────────────────────────────────────────────"
echo "pwd: $(pwd)"
echo
echo "recent commits:"
git log --oneline -20 2>/dev/null || echo "  (not a git repo)"
echo
echo "working tree:"
if [[ -n "$(git status --short 2>/dev/null)" ]]; then
  git status --short
  echo "  ^ uncommitted changes — read these before doing anything"
else
  echo "  clean"
fi

if [[ -f AGENTS.md ]]; then
  echo
  echo "── context file present: AGENTS.md ($(wc -l < AGENTS.md) lines) ──"
else
  echo
  echo "WARNING: no AGENTS.md — project conventions and gates are undocumented."
fi

if [[ -f "$STATE" ]]; then
  echo
  echo "── state ($STATE) ─────────────────────────────────────────"
  cat "$STATE"
else
  echo
  echo "note: no state file at $STATE (create one at session end)"
fi

echo
echo "── verify baseline ────────────────────────────────────────"
if eval "$GATE"; then
  echo
  echo "BASELINE GREEN — safe to start new work."
  exit 0
fi

echo
echo "BASELINE RED — do NOT start new work."
echo "Report the failure above and resolve it first: adding to a broken"
echo "baseline makes every later signal uninterpretable."
exit 1
