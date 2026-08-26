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
TAG=""; PREC="full"; SELECT="vote"   # SELECT: vote (nonempty majority) | wholefunc (recover code-fence patches)
while [ $# -gt 0 ]; do case "$1" in --tag) TAG="$2"; shift 2;; --precision) PREC="$2"; shift 2;; --select) SELECT="$2"; shift 2;; *) shift;; esac; done

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
MODELNAME="${FULLNAME}-${PREC}"
# qwen35 quirk: the board's Q4 cell for the 35B-A3B model reads qwen3.5-35b-a3b-q4f (the LOCAL GGUF is
# a 3.5; the full-precision API model is 3.6). So the Q4 rescore must write there + stamp that name.
if [ "$KEY" = "qwen35" ] && [ "$PREC" = "q4f" ]; then
  SCORED_DIR="results/scored/qwen3.5-35b-a3b-q4f"; MODELNAME="qwen3.5-35b-a3b-q4f"
fi
# N (denominator) MUST equal the SAME instance count the ORIGINAL run scored (Q4=51), NOT strat50's 20,
# else the before/after is on different sets and meaningless. Read it from the existing scored json.
N=$(python3 -c "import json;d=json.load(open('$SCORED_DIR/swebench_lite.json'));print(d.get('total') or d.get('n') or 51)" 2>/dev/null); [ -n "${N:-}" ] || N=51
echo "[rescore] denominator N=$N (from original $SCORED_DIR)"
# IDS (which instances to evaluate) is set AFTER the vote, from the bugs that actually have a patch.

NS=$(ls "$REP"/output_*_processed.jsonl 2>/dev/null | wc -l)
if [ "$NS" -lt 2 ]; then echo "[rescore] $KEY: only $NS processed sample file(s) in $REP — need >=2 to select. Abort."; exit 1; fi
echo "[rescore] $KEY ($FULLNAME): majority-voting over $NS samples in $REP (N=$N bugs)"

# 1) SELECT: majority vote among NON-EMPTY patches (ignores empty-padded samples that would otherwise
# win the vote for a bug that had valid patches -> empty prediction -> board blanks the cell). Any bug
# with >=1 real patch gets a real prediction; all-empty bugs stay empty (genuine no-fix).
if [ "$SELECT" = "prebuilt" ]; then
  # all_preds.jsonl already written by an upstream selector (e.g. the full rerank). Just re-stamp the
  # model name for consistent report naming and evaluate it — no vote.
  echo "[rescore] SELECT=prebuilt — evaluating existing all_preds.jsonl (rerank output)"
  [ -s "$REP/all_preds.jsonl" ] || { echo "[rescore] no prebuilt all_preds.jsonl"; exit 1; }
  $PY -c "import json;p='$REP/all_preds.jsonl';rows=[json.loads(l) for l in open(p) if l.strip()];[r.__setitem__('model_name_or_path','$MODELNAME') for r in rows];open(p,'w').write('\n'.join(json.dumps(r) for r in rows)+'\n')" 2>/dev/null
elif [ "$SELECT" = "wholefunc" ]; then
  # code-fence recovery for models that dump whole functions instead of SEARCH/REPLACE (the 0.0 MoE).
  echo "[rescore] SELECT=wholefunc — recovering diffs from code fences"
  $PY "$REPO/scripts/swe_wholefunc_postprocess.py" "$KEY" ${TAG:+--tag "$TAG"} \
      || { echo "[rescore] wholefunc postprocess failed"; exit 1; }
  # wholefunc stamps its own model_name in all_preds; re-stamp to <fullname>-<prec> for consistent report naming.
  $PY -c "import json,sys;
p='$REP/all_preds.jsonl';rows=[json.loads(l) for l in open(p) if l.strip()]
[r.__setitem__('model_name_or_path','$MODELNAME') for r in rows]
open(p,'w').write('\n'.join(json.dumps(r) for r in rows)+'\n')" 2>/dev/null
else
  $PY "$REPO/scripts/swe_nonempty_vote.py" "$REP" "$NS" "$MODELNAME" "$REP/all_preds.jsonl" \
      || { echo "[rescore] non-empty vote failed"; exit 1; }
fi
[ -s "$REP/all_preds.jsonl" ] || { echo "[rescore] all_preds.jsonl empty"; exit 1; }
echo "[rescore] selected patches: $(wc -l < "$REP/all_preds.jsonl") bugs"
# evaluate exactly the bugs that got a selected patch; bugs without a patch stay unresolved in N.
mapfile -t IDS < <($PY -c "import json;print('\n'.join(sorted({json.loads(l)['instance_id'] for l in open('$REP/all_preds.jsonl') if l.strip()})))" 2>/dev/null)
[ "${#IDS[@]}" -ge 1 ] || { echo "[rescore] no instance ids from all_preds"; exit 1; }
echo "[rescore] evaluating ${#IDS[@]} instances (denominator N=$N)"

# 2) RE-EVAL with RETRY-ON-ERROR. SWE-bench builds a Docker image per instance; transient build
#    failures (apt/pip 404s, races) show up as "error_instances" and, un-retried, sank qwen27/gemma to
#    a bogus 0.0. We accumulate resolved ids across attempts and retry ONLY the errored instances
#    (their images are cached from attempt 1, so retries almost always succeed).
RUN_ID="agentless_${KEY}${TAG:+_$TAG}_sel"
mkdir -p "$WORK/eval_sel"
report_path(){ ls -t "$REPO/$MODELNAME.$RUN_ID.json" "$REPO"/*."$RUN_ID".json \
  "$WORK/eval_sel"/*"$RUN_ID"*.json "$AGENTLESS"/*"$RUN_ID"*.json 2>/dev/null | head -1; }
declare -A RES
TODO=("${IDS[@]}")
for attempt in 1 2 3; do
  [ "${#TODO[@]}" -eq 0 ] && break
  echo "[rescore] eval attempt $attempt: ${#TODO[@]} instance(s) (max_workers 4)"
  $PY -m swebench.harness.run_evaluation --dataset_name "$DATASET" --predictions_path "$REP/all_preds.jsonl" \
      --run_id "$RUN_ID" --instance_ids "${TODO[@]}" --max_workers 4 --report_dir "$WORK/eval_sel" \
      >/dev/null 2>&1 || true
  RPT=$(report_path); [ -z "$RPT" ] && { echo "[rescore] attempt $attempt: NO report -> abort (score untouched)"; exit 3; }
  while read -r r; do [ -n "$r" ] && RES["$r"]=1; done < <($PY -c "import json;print('\n'.join(json.load(open('$RPT')).get('resolved_ids',[])))" 2>/dev/null)
  mapfile -t TODO < <($PY -c "import json;print('\n'.join(json.load(open('$RPT')).get('error_ids',[])))" 2>/dev/null)
  echo "[rescore] attempt $attempt: resolved=${#RES[@]} errors-left=${#TODO[@]}"
  [ "${#TODO[@]}" -eq 0 ] && break
  docker container prune -f >/dev/null 2>&1; docker network prune -f >/dev/null 2>&1; sleep 5
done

# 3) SAFETY GUARD: if instances are STILL errored after 3 attempts, the eval is unreliable this run —
#    do NOT overwrite (a flaky eval must NEVER blank a real score). >3 leftover errors => keep old.
ERR=${#TODO[@]}; RESN=${#RES[@]}
if [ "$ERR" -gt 3 ]; then
  echo "[rescore] $KEY: $ERR instance(s) STILL errored after 3 attempts -> eval UNRELIABLE, keeping existing score (safe)"; exit 4
fi

# 4) BACKUP the old score, then write it with the ACTUAL selection method recorded (so the board card
#    shows exactly which settings produced this number).
case "$SELECT" in
  prebuilt) SELLABEL="rerank: regression + reproduction-tests (--max_samples 40) over ${NS} repair samples" ;;
  wholefunc) SELLABEL="whole-function code-fence recovery + majority vote over ${NS}" ;;
  *) SELLABEL="majority_vote_over_${NS}" ;;
esac
cp "$SCORED_DIR/swebench_lite.json" "$SCORED_DIR/swebench_lite.json.pre_rescore" 2>/dev/null
RESIDS=$(printf '%s\n' "${!RES[@]}" | paste -sd, -)
$PY - "$SCORED_DIR/swebench_lite.json" "$N" "$NS" "$RESN" "$RESIDS" "$SELLABEL" <<'PYEOF'
import json, sys, os
scored_p, n, ns, resn = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
resids = [x for x in sys.argv[5].split(',') if x]
sellabel = sys.argv[6]
old = None
try: old = json.load(open(scored_p)).get('score')
except Exception: pass
os.makedirs(os.path.dirname(scored_p), exist_ok=True)
json.dump({
    "score": resn / n if n else 0.0, "resolved": resn, "total": n,
    "metric": "swebench_lite_resolved_pct", "benchmark": "swebench_lite",
    "selection": sellabel, "repair_samples": ns, "detail": {"resolved_ids": resids},
}, open(scored_p, "w"))
print(f"[rescore] {resn}/{n} = {100*resn/n:.1f}% ({sellabel}, was {old}) -> {scored_p}")
PYEOF
