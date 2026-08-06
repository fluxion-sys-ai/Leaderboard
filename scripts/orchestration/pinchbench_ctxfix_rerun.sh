#!/bin/bash
# Context-fix PinchBench rerun: qwen2.5, qwen3, granite lost 34-44/116 tasks to 32K
# context overflow. Rerun them at 64K (granite native; qwen2.5/qwen3 via YaRN). Only these
# 3 benefit (glm/mistral don't overflow, gemma-2 is 8K-capped). Waits for batched + GPU free.
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
LOG=/tmp/pinchbench_ctxfix.log
echo "[ctxfix] waiting for batched + GPU free $(date -u +%T)" > $LOG
while pgrep -f 'batched_fix_run.sh' >/dev/null || pgrep -f 'llama-b9892/llama-server' >/dev/null; do sleep 120; done
echo "[ctxfix] GPU free -> rerun overflow models at 64K $(date -u +%T)" >> $LOG
mkdir -p /home/ubuntu/pinchbench-skill/results/_pre_ctxfix64k
for M in granite-4.1-8b qwen2.5-7b-instruct qwen3-8b; do
  pkill -f 'llama-server' 2>/dev/null; sleep 6
  # keep the old 32K result aside so import picks up the fresh 64K run
  mv -f /home/ubuntu/pinchbench-skill/results/*edge-${M}*.json /home/ubuntu/pinchbench-skill/results/_pre_ctxfix64k/ 2>/dev/null
  echo "[ctxfix] $M @64K $(date -u +%T)" >> $LOG
  bash scripts/pinchbench_run.sh "$M" >> $LOG 2>&1 || echo "[ctxfix] $M failed" >> $LOG
  pkill -f 'llama-server' 2>/dev/null; sleep 10
  python3 import_pinchbench.py >> $LOG 2>&1
  python3 -m src.report.build_leaderboard >> $LOG 2>&1
  cp -f leaderboard.html /home/ubuntu/edge_leaderboard.html 2>/dev/null
  NEW=$(python3 -c "import json;print(round(json.load(open('results/scored/$M/pinchbench.json'))['score']*100,1))" 2>/dev/null)
  echo "[ctxfix] $M new PinchBench = ${NEW} $(date -u +%T)" >> $LOG
done
echo "[ctxfix] ALL DONE $(date -u +%T)" >> $LOG
