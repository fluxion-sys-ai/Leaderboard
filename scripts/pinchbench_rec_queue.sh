#!/bin/bash
# Queued PinchBench-rec: waits for the Q4 track to finish + GPU free, then SMOKE-gates gemma
# (5 tasks) and, if it passes, runs the full 116-task suite for the 3 frontier Q4 models.
# no_think + rec sampling (thinking-ON zeroes this benchmark). Muse Q4 blocked. Runs detached.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
log(){ echo "[$(date +'%F %T')] $*"; }

log "pb-rec-queue: waiting for qwen35-Q4 to finish + GPU free..."
until [ -f results/scored/qwen3.5-35b-a3b-q4f/aime2026.json ] \
   && ! pgrep -f "models_q4_frontier" >/dev/null \
   && ! pgrep -f "llama-b9892/llama-server" >/dev/null; do
  sleep 120
done
log "Q4 done + GPU free. Running SMOKE (gemma, 5 tasks) at no_think + rec sampling."

bash scripts/pinchbench_rec_run.sh gemma 5 > /tmp/pb_rec_smoke.log 2>&1 || true
sleep 2
PASS=$(grep -E "Task task.*: [0-9.]+/1.0" /tmp/pb_rec_smoke.log 2>/dev/null | grep -cvE ": 0.0/" || echo 0)
DONE=$(grep -cE "Task task.*: [0-9.]+/1.0" /tmp/pb_rec_smoke.log 2>/dev/null || echo 0)
log "smoke: $PASS/$DONE passed"
if [ "${PASS:-0}" -lt 1 ]; then
  log "SMOKE FAILED (0 passed) — no_think+rec is still broken. ABORTING; needs a human look. NOT running full."
  exit 1
fi

log "smoke OK — running FULL 116-task suite for gemma / qwen27 / qwen35 (sequential)."
for m in gemma qwen27 qwen35; do
  log "pb-rec FULL $m starting"
  bash scripts/pinchbench_rec_run.sh "$m" >> /tmp/pb_rec_${m}_full.log 2>&1 || log "pb-rec $m failed"
  log "pb-rec FULL $m done"
done
log "pb-rec-queue COMPLETE — results in pinchbench-skill/results/ (import + tab-map pending)."
