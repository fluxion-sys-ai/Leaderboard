#!/bin/bash
set -uo pipefail
cd /home/aliixh/.openclaw/workspace/edge-intelligence-benchmark || exit 1
LOG=logs_qwen27_q4_2x_rerun.log
echo "=== qwen27 Q4 2x rerun: waiting for GPU (Q4 SWE reruns) to finish $(date -u) ===" > "$LOG"
while ps -eo args | grep -qE "[s]we_full_select.sh|[g]enerate_reproduction_tests"; do sleep 120; done
echo "=== GPU free -> qwen27 Q4 2x fresh run $(date -u) ===" >> "$LOG"
TS=$(date -u +%s)
mv results/terminalbench_q4/qwen27_2x24/qwen27q2x "results/terminalbench_q4/qwen27_2x24/qwen27q2x_variance_bak_${TS}" 2>/dev/null
env TB_MULT=2.0 TB_MAX_TOKENS=1000000 TB_RUNID="qwen27q2x" TB_OUT="results/terminalbench_q4/qwen27_2x24" \
  bash scripts/terminalbench_q4_run.sh qwen27 >> "$LOG" 2>&1
echo "=== qwen27 Q4 2x rerun DONE $(date -u) ===" >> "$LOG"
