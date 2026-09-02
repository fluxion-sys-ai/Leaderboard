#!/bin/bash
# Q4 SWE-Lite reruns, reordered per operator request: gemma FIRST, muse LAST.
# muse was stalling at ~24 min/test (~12 h ETA) on the b10433 build with thinking-on; gemma uses the
# b9892 build (same as qwen27/qwen38, which completed fine) so it should run at a normal rate.
# Serial by necessity — single GPU. Each step: swe_full_select.sh <k> in Q4-local mode (SWE_OR unset).
set -uo pipefail
cd /home/aliixh/.openclaw/workspace/edge-intelligence-benchmark || exit 1
LOG=logs_q4swe_reorder.log
echo "=== Q4 SWE reorder (gemma -> muse) start $(date -u) ===" >> "$LOG"
for k in gemma muse; do
  echo "--- [$k] start $(date -u) ---" >> "$LOG"
  bash scripts/swe_full_select.sh "$k" >> "logs_swe_fullselect_${k}.log" 2>&1 \
    || echo "[$k] full-select kept old score (guard)" >> "$LOG"
  echo "--- [$k] done $(date -u) ---" >> "$LOG"
done
echo "=== Q4 SWE reorder COMPLETE $(date -u) ===" >> "$LOG"
