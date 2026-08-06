#!/bin/bash
# PRIORITIZED: (1) context-fix PinchBench rerun on the 3 overflow models @64K, THEN
# (2) resume the batched benchmarks (cache-aware — only the unfinished models/cells run),
# judges, rescore, rebuild. One sequence = no GPU thrash.
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
LOG=/tmp/pinch_then_batched.log
echo "[seq] START $(date -u +%T)" > $LOG

# ---- (1) context-fix PinchBench: granite(64K native), qwen2.5/qwen3(64K yarn) ----
mkdir -p /home/ubuntu/pinchbench-skill/results/_pre_ctxfix64k
for M in granite-4.1-8b qwen2.5-7b-instruct qwen3-8b; do
  pkill -f 'llama-server' 2>/dev/null; sleep 6
  mv -f /home/ubuntu/pinchbench-skill/results/*edge-${M}*.json /home/ubuntu/pinchbench-skill/results/_pre_ctxfix64k/ 2>/dev/null
  echo "[seq] PinchBench $M @64K $(date -u +%T)" >> $LOG
  bash scripts/pinchbench_run.sh "$M" >> $LOG 2>&1 || echo "[seq] $M failed" >> $LOG
  pkill -f 'llama-server' 2>/dev/null; sleep 10
  python3 import_pinchbench.py >> $LOG 2>&1
  python3 -m src.report.build_leaderboard >> $LOG 2>&1
  cp -f leaderboard.html /home/ubuntu/edge_leaderboard.html 2>/dev/null
  NEW=$(python3 -c "import json;print(round(json.load(open('results/scored/$M/pinchbench.json'))['score']*100,1))" 2>/dev/null)
  echo "[seq]   -> $M PinchBench = ${NEW} (context-fixed) $(date -u +%T)" >> $LOG
done
echo "[seq] context rerun DONE $(date -u +%T)" >> $LOG

# ---- (2) resume batched benchmarks (cache-aware) + judge + rescore + build ----
pkill -f 'llama-server' 2>/dev/null; sleep 6
MODELS=$(python3 scripts/top_models.py 15 | tr '\n' ' ')
echo "[seq] batched resume: $MODELS $(date -u +%T)" >> $LOG
python3 run_benchmark.py --models $MODELS --benchmarks pinchbench_clawd ruler simpleqa gpqa_diamond >> $LOG 2>&1
python3 judge_simpleqa.py >> $LOG 2>&1
python3 import_pinchbench.py >> $LOG 2>&1
python3 rescore_all.py >> $LOG 2>&1
python3 -m src.report.build_leaderboard >> $LOG 2>&1
cp -f leaderboard.html /home/ubuntu/edge_leaderboard.html 2>/dev/null
echo "[seq] ALL DONE $(date -u +%T)" >> $LOG
