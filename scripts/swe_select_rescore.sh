#!/bin/bash
# Majority-vote patch SELECTION + re-eval + re-score for a COMPLETED Agentless SWE run.
#
# THE BUG THIS FIXES: repair (--max_samples N) generates output_0_processed.jsonl ..
# output_{N-1}_processed.jsonl (N candidate patches per bug), but swe_agentless_run.sh evaluated only
# output_0 (the greedy sample) — so repair-10 was wasted and the score was ~1-sample level, NOT the
# multi-sample number published for Agentless. This runs Agentless' own rerank.py MAJORITY VOTING
# (no --regression/--reproduction => zero extra Docker/model cost) to pick the most-common normalized
# patch per bug, re-evaluates that selection, and OVERWRITES the scored json. It reuses the patches
# already generated — no regeneration, no extra OpenRouter spend.
#
# Usage: swe_select_rescore.sh <muse|qwen27|qwen35|qwen38|gemma> [--tag orf] [--precision full|q4f]
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
AGENTLESS=/home/aliixh/Agentless
export PYTHONPATH="$AGENTLESS:${PYTHONPATH:-}"
PY=python3
DATASET=princeton-nlp/SWE-bench_Lite
KEY="${1:?usage: swe_select_rescore.sh <key> [--tag S] [--precision full|q4f]}"; shift
TAG=""; PREC="full"
while [ $# -gt 0 ]; do case "$1" in --tag) TAG="$2"; shift 2;; --precision) PREC="$2"; shift 2;; *) shift;; esac; done

case "$KEY" in
  muse)   FULLNAME="muse-glimmer-30b" ;;
  qwen27) FULLNAME="qwen3.6-27b" ;;
  qwen35) FULLNAME="qwen3.6-35b-a3b" ;;
  gemma)  FULLNAME="gemma-4-31b" ;;
  qwen38) FULLNAME="qwen3.8-27b" ;;
  *) echo "unknown key: $KEY"; exit 2 ;;
esac

WORK="results/swe_agentless/${KEY}${TAG:+-$TAG}"
REP="$WORK/repair"
# Write the majority-vote score straight to the BOARD dir (<fn>-full), NOT the tagged -full-orf dir.
# The guardian promotes/removes -full-orf and treats -full as done, so writing -full-orf lets the
# greedy score win the race. Writing -full directly makes the majority-vote score authoritative.
SCORED_DIR="results/scored/${FULLNAME}-${PREC}"
mapfile -t IDS < configs/swe_lite_strat50.txt
CLEAN=(); for i in "${IDS[@]}"; do [ -n "$i" ] && CLEAN+=("$i"); done; IDS=("${CLEAN[@]}")
N=${#IDS[@]}

NS=$(ls "$REP"/output_*_processed.jsonl 2>/dev/null | wc -l)
if [ "$NS" -lt 2 ]; then echo "[rescore] $KEY: only $NS processed sample file(s) in $REP — need >=2 to select. Abort."; exit 1; fi
echo "[rescore] $KEY ($FULLNAME): majority-voting over $NS samples in $REP (N=$N bugs)"

# 1) SELECT: majority vote among NON-EMPTY patches (ignores empty-padded samples that would otherwise
# win the vote for a bug that had valid patches -> empty prediction -> board blanks the cell). Any bug
# with >=1 real patch gets a real prediction; all-empty bugs stay empty (genuine no-fix).
$PY "$REPO/scripts/swe_nonempty_vote.py" "$REP" "$NS" "${FULLNAME}-full" "$REP/all_preds.jsonl" \
    || { echo "[rescore] non-empty vote failed"; exit 1; }
[ -s "$REP/all_preds.jsonl" ] || { echo "[rescore] all_preds.jsonl empty"; exit 1; }
echo "[rescore] selected patches: $(wc -l < "$REP/all_preds.jsonl") bugs"

# 2) RE-EVAL the selected patch set
RUN_ID="agentless_${KEY}${TAG:+_$TAG}_sel"
mkdir -p "$WORK/eval_sel"
$PY -m swebench.harness.run_evaluation \
    --dataset_name "$DATASET" --predictions_path "$REP/all_preds.jsonl" \
    --run_id "$RUN_ID" --instance_ids "${IDS[@]}" --max_workers 6 --report_dir "$WORK/eval_sel" \
    || echo "[rescore] WARN: harness non-zero (some unresolved)"
REPORT=$(ls -t "$AGENTLESS/agentless.$RUN_ID.json" "$REPO/agentless.$RUN_ID.json" \
              "$WORK/eval_sel/agentless.$RUN_ID.json" "$AGENTLESS"/agentless.*"$RUN_ID"*.json 2>/dev/null | head -1)
[ -z "$REPORT" ] && REPORT="__MISSING__"
echo "[rescore] report: $REPORT"

# 3) RE-SCORE (overwrite the greedy-only score with the majority-vote score)
$PY - "$REPORT" "$SCORED_DIR/swebench_lite.json" "$N" "$NS" <<'PYEOF'
import json, sys, os
rep_p, scored_p, n, ns = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
if not os.path.exists(rep_p):
    print("[rescore] no report -> leaving existing score untouched"); sys.exit(3)
rep = json.load(open(rep_p))
resolved = rep.get("resolved_instances", len(rep.get("resolved_ids", [])))
os.makedirs(os.path.dirname(scored_p), exist_ok=True)
json.dump({
    "score": resolved / n if n else 0.0,
    "resolved": resolved, "total": n,
    "metric": "swebench_lite_resolved_pct", "benchmark": "swebench_lite",
    "selection": f"majority_vote_over_{ns}",
    "detail": {"resolved_ids": rep.get("resolved_ids", []),
               "unresolved_ids": rep.get("unresolved_ids", []),
               "completed_ids": rep.get("completed_ids", [])},
}, open(scored_p, "w"))
print(f"[rescore] {resolved}/{n} = {100*resolved/n:.1f}% (majority-vote over {ns}) -> {scored_p}")
PYEOF
