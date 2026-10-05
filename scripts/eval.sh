#!/usr/bin/env bash
# eval.sh — run the harness regression suite and compare against a baseline.
#
# WHY THIS EXISTS
#   Without a fixed task set you cannot tell whether a harness change (a new skill,
#   a context file, a prompt rule) actually helped or merely felt better. Research on
#   agent harnesses shows the same model swinging 15-20 points across harnesses, so
#   "it feels improved" is not evidence. This script turns the harness itself into
#   something measurable.
#
# WHAT IT DOES
#   For each case in tests/cases.json:
#     1. copy the repo into a throwaway worktree (so cases cannot contaminate each other)
#     2. run `dsh --profile headless --json "<prompt>"` inside it, capturing events
#     3. judge the result with a DETERMINISTIC check:
#          "cmd"   -> exit 0 means pass  (preferred: real, mechanical)
#          "regex" -> response matches   (fallback, weaker)
#     4. record pass/fail, wall time, turns, and tool-call count
#   Then write a results file and diff it against the previous run.
#
# USAGE
#   bash scripts/eval.sh                    # run cases, label "current"
#   bash scripts/eval.sh --label with-agents-md
#   bash scripts/eval.sh --case 002         # one case
#   bash scripts/eval.sh --dry-run          # show what would run
#   bash scripts/eval.sh --compare a b      # diff two saved runs
#
# WHY "cmd" IS PREFERRED
#   An LLM-judged "did it do well?" is itself a weak oracle: the same literature that
#   motivates this harness found only 44% of self-generated tests actually validated
#   the correct fix. Prefer a command whose exit code a human could also check.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

CASES_FILE="${CASES_FILE:-tests/cases.json}"
RESULTS_DIR="${RESULTS_DIR:-.eval/results}"
LABEL="current"
ONLY_CASE=""
DRY_RUN=0
TIMEOUT_SECS="${EVAL_TIMEOUT_SECS:-900}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)   LABEL="$2"; shift 2 ;;
    --case)    ONLY_CASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --compare) shift; COMPARE_A="$1"; COMPARE_B="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "${COMPARE_A:-}" ]]; then
  node -e '
    const fs=require("fs");
    const [a,b]=process.argv.slice(1).map(p=>JSON.parse(fs.readFileSync(p,"utf8")));
    const byId=o=>Object.fromEntries(o.cases.map(c=>[c.id,c]));
    const A=byId(a),B=byId(b);
    console.log(`base: ${a.label}\nhead: ${b.label}\n`);
    console.log("id     base  head  delta   time            tools          tokens");
    for(const id of new Set([...Object.keys(A),...Object.keys(B)])){
      const x=A[id],y=B[id];
      const f=v=>v?(v.passed?"PASS":"FAIL"):"----";
      const d=(x&&y)?(y.passed===x.passed?"      ":(y.passed?" FIXED":" BROKE")):"";
      const s=v=>v==null?"-":String(v);
      console.log(`${id.padEnd(6)} ${f(x).padEnd(5)} ${f(y).padEnd(5)} ${d.padEnd(7)} ${s(x&&x.seconds)}s->${s(y&&y.seconds)}s`.padEnd(52)
        + ` ${s(x&&x.toolCalls)}->${s(y&&y.toolCalls)}`.padEnd(15) + ` ${s(x&&x.tokens)}->${s(y&&y.tokens)}`);
    }
    const rate=o=>o.passed/o.total;
    console.log(`\npass rate: ${(rate(a)*100).toFixed(0)}% (${a.passed}/${a.total}) -> ${(rate(b)*100).toFixed(0)}% (${b.passed}/${b.total})`);
  ' "$RESULTS_DIR/$COMPARE_A.json" "$RESULTS_DIR/$COMPARE_B.json"
  exit $?
fi

[[ -f "$CASES_FILE" ]] || { echo "no cases file at $CASES_FILE" >&2; exit 2; }

command -v dsh >/dev/null || { echo "dsh not on PATH" >&2; exit 2; }

CASE_IDS=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).cases.map(c=>c.id).join(" "))' "$CASES_FILE")

if [[ $DRY_RUN -eq 1 ]]; then
  echo "cases file : $CASES_FILE"
  echo "label      : $LABEL"
  echo "cases      : $CASE_IDS"
  node -e '
    const {cases}=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    for(const c of cases) console.log(`  ${c.id}  check=${c.check.cmd?"cmd":("regex")}  ${c.prompt.slice(0,70)}`);
  ' "$CASES_FILE"
  exit 0
fi

mkdir -p "$RESULTS_DIR"
WORKDIR="$(mktemp -d -t harness-eval-XXXXXX)"
RESULTS_FILE="$RESULTS_DIR/$LABEL.json"
CASE_RESULTS=()

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "harness eval — label=$LABEL  cases=$(echo $CASE_IDS | wc -w)"
echo "workdir: $WORKDIR"
echo

for ID in $CASE_IDS; do
  [[ -n "$ONLY_CASE" && "$ONLY_CASE" != "$ID" ]] && continue

  PROMPT=$(node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[2],"utf8")).cases.find(x=>x.id===process.argv[1]);process.stdout.write(c.prompt)' "$ID" "$CASES_FILE")
  CHECK_CMD=$(node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[2],"utf8")).cases.find(x=>x.id===process.argv[1]);process.stdout.write(c.check.cmd||"")' "$ID" "$CASES_FILE")
  CHECK_RE=$(node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[2],"utf8")).cases.find(x=>x.id===process.argv[1]);process.stdout.write(c.check.regex||"")' "$ID" "$CASES_FILE")

  echo "── ${ID} ────────────────────────────────────────────────"
  echo "   prompt: ${PROMPT:0:100}"

  # Isolated copy so cases cannot contaminate each other, with dependencies
  # carried over (installing per case would dominate runtime).
  CASE_DIR="$WORKDIR/$ID"
  mkdir -p "$CASE_DIR"
  tar -c --exclude=.git --exclude=.eval --exclude=node_modules -C "$REPO_ROOT" . 2>/dev/null | tar -x -C "$CASE_DIR"
  [[ -d "$REPO_ROOT/node_modules" ]] && ln -s "$REPO_ROOT/node_modules" "$CASE_DIR/node_modules"
  git -C "$CASE_DIR" init -q 2>/dev/null && git -C "$CASE_DIR" add -A 2>/dev/null && git -C "$CASE_DIR" -c user.email=e@e -c user.name=e commit -qm baseline 2>/dev/null

  START=$(date +%s)
  ( cd "$CASE_DIR" && timeout "$TIMEOUT_SECS" dsh --profile headless --json "$PROMPT" ) > "$WORKDIR/$ID.events" 2> "$WORKDIR/$ID.err"
  RUN_EXIT=$?
  END=$(date +%s)
  SECONDS_ELAPSED=$((END - START))

  META=$(node -e '
    const fs=require("fs");
    let finalText="", streamed="", toolCalls=0, turns=0, tokens=0;
    for(const line of fs.readFileSync(process.argv[1],"utf8").split("\n")){
      if(!line.trim())continue;
      let e; try{e=JSON.parse(line)}catch{continue}
      if(e.type==="final"&&typeof e.text==="string") finalText+=e.text;
      else if(e.type==="text"&&typeof e.text==="string") streamed+=e.text;
      else if(e.type==="tool_call") toolCalls++;
      else if(e.type==="status"&&e.phase==="turn_start") turns++;
      else if(e.type==="status"&&e.phase==="step_end"&&e.usage) tokens+=(e.usage.totalTokens||0);
    }
    process.stdout.write(JSON.stringify({text:finalText||streamed,toolCalls,turns,tokens}));
  ' "$WORKDIR/$ID.events" 2>/dev/null)
  [[ -z "$META" ]] && META='{"text":"","toolCalls":0,"turns":0,"tokens":0}'

  RESPONSE=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).text)' "$META")
  TOOL_CALLS=$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).toolCalls))' "$META")
  TURNS=$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).turns))' "$META")
  TOKENS=$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).tokens))' "$META")
  printf '%s' "$RESPONSE" > "$WORKDIR/$ID.response"

  PASSED=0
  REASON=""
  KIND="FAIL"
  if [[ $RUN_EXIT -ne 0 ]]; then
    # A non-zero dsh exit is an infrastructure failure, not a test failure.
    # Reporting it as "FAIL" would blame the harness for a broken runner.
    KIND="INFRA"
    REASON="dsh exited ${RUN_EXIT}; see $(basename "$WORKDIR")/$ID.err"
  elif [[ -z "${RESPONSE//[[:space:]]/}" ]]; then
    # No assistant text at all. Never let a regex check "pass" against an empty
    # string, and never let it silently judge raw event JSON instead of an answer.
    KIND="NO-OUTPUT"
    REASON="agent returned no final text (exit 0); tool calls=${TOOL_CALLS}"
  elif [[ -n "$CHECK_CMD" ]]; then
    # EVAL_RESPONSE lets a case's check inspect the agent's final answer, so a
    # `cmd` check beats a prose regex without needing a bespoke runner.
    if ( cd "$CASE_DIR" && EVAL_RESPONSE="$WORKDIR/$ID.response" eval "$CHECK_CMD" ) > "$WORKDIR/$ID.check" 2>&1; then
      PASSED=1; KIND="PASS"; REASON="cmd passed: $CHECK_CMD"
      sed 's/^/         /' "$WORKDIR/$ID.check"
    else
      REASON="cmd failed (exit $?): $CHECK_CMD"
      sed 's/^/         /' "$WORKDIR/$ID.check"
    fi
  elif [[ -n "$CHECK_RE" ]]; then
    if echo "$RESPONSE" | grep -Eq "$CHECK_RE"; then
      PASSED=1; KIND="PASS"; REASON="response matched: $CHECK_RE"
    else
      REASON="response did not match: $CHECK_RE"
    fi
  else
    KIND="NO-CHECK"
    REASON="no check defined — treated as FAIL (an unchecked case measures nothing)"
  fi

  case "$KIND" in
    PASS)      echo "   PASS  (${SECONDS_ELAPSED}s, ${TOOL_CALLS} tool calls)" ;;
    INFRA)     echo "   INFRA (${SECONDS_ELAPSED}s) — runner problem, not a test result"; echo "         ${REASON}" ;;
    NO-OUTPUT) echo "   NO-OUTPUT (${SECONDS_ELAPSED}s, ${TOOL_CALLS} tool calls)"; echo "         ${REASON}" ;;
    *)         echo "   FAIL  (${SECONDS_ELAPSED}s, ${TOOL_CALLS} tool calls)"; echo "         ${REASON}" ;;
  esac
  node -e '
    const fs=require("fs");
    const [id,passed,secs,tools,turns,tokens,reason,exitCode,responseFile,outFile,label,kind]=process.argv.slice(1);
    let response="";try{response=fs.readFileSync(responseFile,"utf8")}catch{}
    const rec={id,passed:passed==="1",kind,seconds:+secs,toolCalls:+tools,turns:+turns,tokens:+tokens,reason,exitCode:+exitCode,response:response.slice(0,8000),label};
    fs.writeFileSync(outFile,JSON.stringify(rec));
  ' "$ID" "$PASSED" "$SECONDS_ELAPSED" "$TOOL_CALLS" "$TURNS" "$TOKENS" "$REASON" "$RUN_EXIT" "$WORKDIR/$ID.response" "$WORKDIR/$ID.rec" "$LABEL" "$KIND"

  CASE_RESULTS+=("$WORKDIR/$ID.rec")
  echo
done

node -e '
  const fs=require("fs");
  const [label,casesFile,outFile,...recs]=process.argv.slice(1);
  const cases=recs.map(p=>JSON.parse(fs.readFileSync(p,"utf8")));
  const passed=cases.filter(c=>c.passed).length;
  const doc={label,at:new Date().toISOString(),casesFile,total:cases.length,passed,passRate:cases.length?passed/cases.length:0,cases};
  fs.writeFileSync(outFile,JSON.stringify(doc,null,2));
  console.log("════════════════════════════════════════════════════════");
  console.log(`pass rate: ${passed}/${cases.length}  (${((doc.passRate)*100).toFixed(0)}%)`);
  console.log(`results  : ${outFile}`);
  const prev=fs.existsSync(".eval/results/current.json")&&label!=="current"?".eval/results/current.json":null;
  process.exit(0);
' "$LABEL" "$CASES_FILE" "$RESULTS_FILE" "${CASE_RESULTS[@]}"

echo
echo "compare a change:  bash scripts/eval.sh --label with-change && bash scripts/eval.sh --compare current with-change"
