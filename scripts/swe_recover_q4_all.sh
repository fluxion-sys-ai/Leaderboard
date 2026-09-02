#!/bin/bash
# Q4 dropped-patch recovery across all 5 Q4 models, SEQUENTIALLY. WAITS for the full-precision
# recovery rollout (swe_recover_all.sh) to finish first, so Docker isn't overloaded. REPORT-ONLY.
set -uo pipefail
cd /home/aliixh/.openclaw/workspace/edge-intelligence-benchmark || exit 1
LOG=logs_swe_recover_q4_all.log
echo "=== Q4 recover-all: waiting for full-precision rollout to finish $(date -u) ===" > "$LOG"
# wait until the full-precision rollout driver is gone (avoid Docker thrash)
while ps -eo args | grep -qE "[s]we_recover_all.sh|[s]we_recover_eval.sh "; do sleep 60; done
echo "=== full rollout done -> starting Q4 recovery $(date -u) ===" >> "$LOG"
for k in qwen38 qwen27 gemma muse qwen35; do
  echo "--- Q4 $k $(date -u) ---" >> "$LOG"
  bash scripts/swe_recover_eval_q4.sh "$k" >> "$LOG" 2>&1 || echo "$k: non-zero" >> "$LOG"
  grep RECOVER_RESULT "logs_swe_recover_q4_${k}.log" 2>/dev/null | tail -1 | sed "s/^/  Q4 $k -> /" >> "$LOG"
done
echo "=== Q4 recover-all DONE $(date -u) ===" >> "$LOG"
