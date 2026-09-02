#!/bin/bash
# Recover dropped SEARCH/REPLACE patches for a model, then gold-eval on the strat-20 sample.
# REPORT-ONLY: writes *_recovered + eval_recover + a summary line; does NOT touch the board/scored.
# Detached-safe: run via `setsid nohup bash scripts/swe_recover_eval.sh qwen38 &` so session cycling
# can't kill it. Result lands in logs_swe_recover_<key>.log (grep RECOVER_RESULT).
set -uo pipefail
cd /home/aliixh/.openclaw/workspace/edge-intelligence-benchmark || exit 1
KEY="${1:-qwen38}"
declare -A FULL=( [qwen38]=qwen3.8-27b [muse]=muse-glimmer-30b [qwen27]=qwen3.6-27b [gemma]=gemma-4-31b [qwen35]=qwen3.6-35b-a3b )
MODEL="${FULL[$KEY]}"
LOG="logs_swe_recover_${KEY}.log"
RUNID="${KEY}_recover_test"
echo "=== recover+eval $KEY start $(date -u) ===" > "$LOG"

python3 scripts/swe_recover_dropped.py "$KEY" --tag orf >> "$LOG" 2>&1

IDS=$(tr '\n' ' ' < configs/swe_lite_sample.txt)
echo "=== gold eval $(date -u) ===" >> "$LOG"
python3 -m swebench.harness.run_evaluation --dataset_name princeton-nlp/SWE-bench_Lite \
  --predictions_path "results/swe_agentless/${KEY}-orf/repair/all_preds_recovered.jsonl" \
  --run_id "$RUNID" --instance_ids $IDS --max_workers 4 \
  --report_dir "results/swe_agentless/${KEY}-orf/eval_recover" >> "$LOG" 2>&1

echo "=== extract result $(date -u) ===" >> "$LOG"
python3 - "$MODEL" "$RUNID" >> "$LOG" 2>&1 <<'PY'
import json, glob, sys
model, runid = sys.argv[1], sys.argv[2]
cands = glob.glob(f"{model}.{runid}.json") + glob.glob(f"*{runid}*.json")
if cands:
    d = json.load(open(cands[0]))
    r = d.get("resolved_instances") or 0
    print(f"RECOVER_RESULT: resolved {r}/20 = {round(100*r/20,1)}%  (old majority-vote 5/20 = 25%)")
    print("resolved_ids:", d.get("resolved_ids"))
else:
    print("RECOVER_RESULT: no report json found")
PY
echo "=== ALL DONE $(date -u) ===" >> "$LOG"
