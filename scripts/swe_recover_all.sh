#!/bin/bash
# Roll the dropped-patch recovery + gold-eval across the remaining full-precision models, SEQUENTIALLY
# (one at a time -> no Docker thrash, no collision with the GPU's terminal-bench containers).
# REPORT-ONLY per model: writes *_recovered + eval_recover + a RECOVER_RESULT line in each log.
# Detached-safe. Result lines: grep RECOVER_RESULT logs_swe_recover_<key>.log
set -uo pipefail
cd /home/aliixh/.openclaw/workspace/edge-intelligence-benchmark || exit 1
DRIVER_LOG=logs_swe_recover_all.log
echo "=== recover-all start $(date -u) ===" > "$DRIVER_LOG"
for k in qwen38 qwen27 gemma muse qwen35; do
  echo "--- $k $(date -u) ---" >> "$DRIVER_LOG"
  bash scripts/swe_recover_eval.sh "$k" >> "$DRIVER_LOG" 2>&1 || echo "$k: non-zero" >> "$DRIVER_LOG"
  grep RECOVER_RESULT "logs_swe_recover_${k}.log" 2>/dev/null | tail -1 | sed "s/^/  $k -> /" >> "$DRIVER_LOG"
done
echo "=== recover-all DONE $(date -u) ===" >> "$DRIVER_LOG"
