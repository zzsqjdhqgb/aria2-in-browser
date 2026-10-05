#!/usr/bin/env bash
# check-claims.sh — deterministic checker for an agent's written answer.
#
# Used by scripts/eval.sh as a case's `cmd` check. The agent's final text is
# available at $EVAL_RESPONSE.
#
# WHY A SCRIPT INSTEAD OF A REGEX
#   A single regex over prose is brittle in both directions: it produced a false
#   FAIL on a correct answer (the agent listed the methods across a Markdown table,
#   so explanatory text sat between the terms a tight pattern expected). Worse, a
#   loose regex would have falsely PASSED an answer that merely name-dropped the
#   methods without stating what a client would wrongly conclude.
#
#   This checker asserts each SEMANTIC claim independently, case-insensitively, and
#   tolerates arbitrary prose between them. It is still a lexical check — it cannot
#   tell whether the reasoning is sound — but it fails loudly and predictably, and
#   every claim it requires is something a human can also verify in the source.
#
# Exit 0 = answer contains every required claim. Exit 1 = missing at least one.
set -uo pipefail

RESP="${EVAL_RESPONSE:?EVAL_RESPONSE must point at the agent response file}"
[[ -f "$RESP" ]] || { echo "no response file at $RESP" >&2; exit 2; }

MISSING=()

# require <label> <extended-regex>  — greps case-insensitively, whole file, multiline off
require() {
  local label="$1" pattern="$2"
  if grep -Eqi -- "$pattern" "$RESP"; then
    echo "  ok      ${label}"
  else
    echo "  MISSING ${label}"
    MISSING+=("$label")
  fi
}

echo "checking $(wc -c < "$RESP") bytes of response"

# 1. The two methods that are advertised but hard-throw.
require "names addTorrent as advertised-but-throwing" 'addtorrent'
require "names addMetalink as advertised-but-throwing" 'addmetalink'
require "identifies the throw / not-supported behaviour"   'not supported|throw|-32000'

# 2. Fabricated success: methods that return a value implying an action happened.
require "names changePosition as fabricating success"      'changeposition'
require "names changeUri as fabricating success"           'changeuri'

# 3. Configuration that is accepted but not enforced.
require "names max-concurrent-downloads as unenforced"     'max-concurrent-downloads'

# 4. Names the advertisement surface itself (system.listMethods is the contract).
require "references system.listMethods"                    'listmethods'

# 5. States the consequence for a client, not just the method name.
require "states what a client would wrongly conclude"      'conclude|believe|assume|thinks?|expect|wrongly|incorrectly'

# 6. Must not claim BitTorrent works.
if grep -Eqi 'bittorrent (is|are) supported|supports bittorrent' "$RESP"; then
  echo "  WRONG   claims BitTorrent is supported"
  MISSING+=("false-claim: BitTorrent supported")
fi

echo
if [[ ${#MISSING[@]} -eq 0 ]]; then
  echo "ALL CLAIMS PRESENT"
  exit 0
fi
echo "MISSING ${#MISSING[@]} claim(s): ${MISSING[*]}"
exit 1
