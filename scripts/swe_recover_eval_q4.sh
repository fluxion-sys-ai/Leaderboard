#!/bin/bash
# Q4 variant of the dropped-patch recovery + gold-eval. Q4 SWE work dirs are results/swe_agentless/<key>
# (no -orf tag), scored on the strat-51 sample (denominator 51). REPORT-ONLY.
# Result: grep RECOVER_RESULT logs_swe_recover_q4_<key>.log
set -uo pipefail
cd /home/aliixh/.openclaw/workspace/edge-intelligence-benchmark || exit 1
KEY="${1:?usage: swe_recover_eval_q4.sh <key>}"
LOG="logs_swe_recover_q4_${KEY}.log"
RUNID="${KEY}_recover_q4"
SAMPLE="configs/swe_lite_strat50_full51.txt"
echo "=== Q4 recover+eval $KEY start $(date -u) ===" > "$LOG"

python3 scripts/swe_recover_dropped.py "$KEY" --tag "" --sample "$SAMPLE" >> "$LOG" 2>&1

PREDS="results/swe_agentless/${KEY}/repair/all_preds_recovered.jsonl"
[ -s "$PREDS" ] || { echo "RECOVER_RESULT: no recovered preds file" >> "$LOG"; exit 1; }
MODEL=$(python3 -c "import json;print(json.loads(open('$PREDS').readline())['model_name_or_path'])" 2>/dev/null)
IDS=$(tr '\n' ' ' < "$SAMPLE")
echo "=== gold eval $(date -u) (model=$MODEL) ===" >> "$LOG"
python3 -m swebench.harness.run_evaluation --dataset_name princeton-nlp/SWE-bench_Lite \
  --predictions_path "$PREDS" --run_id "$RUNID" --instance_ids $IDS --max_workers 4 \
  --report_dir "results/swe_agentless/${KEY}/eval_recover_q4" >> "$LOG" 2>&1

python3 - "$MODEL" "$RUNID" >> "$LOG" 2>&1 <<'PY'
import json, glob, sys
model, runid = sys.argv[1], sys.argv[2]
cands = glob.glob(f"{model}.{runid}.json") + glob.glob(f"*{runid}*.json")
if cands:
    d = json.load(open(cands[0])); r = d.get("resolved_instances") or 0
    print(f"RECOVER_RESULT: resolved {r}/51 = {round(100*r/51,1)}%")
    print("resolved_ids:", d.get("resolved_ids"))
else:
    print("RECOVER_RESULT: no report json found")
PY
echo "=== ALL DONE $(date -u) ===" >> "$LOG"
