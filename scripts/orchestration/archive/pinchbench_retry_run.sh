#!/bin/bash
# Retry PinchBench (top-8) after the extra-watcher finishes. The first attempt's smoke
# failed on a wrapper arg bug (model name passed twice) — now fixed with `shift`.
# DEFENSIVE against the orphan-server bug: kills any leftover llama-server before starting
# (an orphaned server with no driver must never block us again).
set -u
cd /home/aliixh/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token)"
LOG=/tmp/pinchbench_retry.log

echo "[pb-retry] waiting for extra-watcher (batched benchmarks) to finish... $(date -u +%T)" > $LOG
while pgrep -f 'bash /tmp/extra_benchmarks_run.sh' >/dev/null; do sleep 60; done
echo "[pb-retry] extra-watcher done $(date -u +%T)" >> $LOG
# defensive cleanup: no orphaned server may block us
pkill -f 'llama-server' 2>/dev/null; sleep 5
echo "[pb-retry] GPU clear -> PinchBench on top-8 $(date -u +%T)" >> $LOG

MODELS=$(python3 scripts/top_models.py 8 | tr '\n' ' ')
echo "[pb-retry] top-8: $MODELS" >> $LOG
FIRST=$(echo $MODELS | awk '{print $1}')
echo "[pb-retry] smoke: $FIRST $(date -u +%T)" >> $LOG
bash scripts/pinchbench_run.sh "$FIRST" >> $LOG 2>&1 || echo "[pb-retry] smoke errored" >> $LOG
python3 import_pinchbench.py >> $LOG 2>&1
PB_OK=$(python3 -c "import json,os;p='results/scored/$FIRST/pinchbench.json';print('yes' if os.path.exists(p) and json.load(open(p)).get('score') is not None else 'no')" 2>/dev/null)
if [ "$PB_OK" = "yes" ]; then
  echo "[pb-retry] smoke PASSED -> rest $(date -u +%T)" >> $LOG
  for M in $MODELS; do
    [ "$M" = "$FIRST" ] && continue
    echo "[pb-retry] PinchBench: $M $(date -u +%T)" >> $LOG
    bash scripts/pinchbench_run.sh "$M" >> $LOG 2>&1 || echo "[pb-retry] $M failed" >> $LOG
    pkill -f 'llama-server' 2>/dev/null; sleep 15   # ensure each model's server is cleaned up
  done
  python3 import_pinchbench.py >> $LOG 2>&1
  python3 -m src.report.build_leaderboard >> $LOG 2>&1
  cp -f leaderboard.html /home/aliixh/edge_leaderboard.html 2>/dev/null
  echo "[pb-retry] DONE $(date -u +%T)" >> $LOG
else
  echo "[pb-retry] !! smoke STILL failing after fix — check log" >> $LOG
fi
