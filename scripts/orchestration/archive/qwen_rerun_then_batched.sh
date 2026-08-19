#!/bin/bash
# Corrected: qwen2.5 + qwen3 PinchBench at REAL 128K (YaRN 4x — plain -c 131072 was
# silently capping them at 32K). granite already done @128K (32.8), skipped. Then batched
# benchmarks (cache-aware) + judges + rescore + rebuild.
set -u
cd /home/aliixh/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"; export LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892
LOG=/tmp/qwen_rerun.log
echo "[qwen] START $(date -u +%T)" > $LOG
mkdir -p /home/aliixh/pinchbench-skill/results/_pre_yarn128k
for M in qwen2.5-7b-instruct qwen3-8b; do
  pkill -f 'llama-server' 2>/dev/null; sleep 6
  mv -f /home/aliixh/pinchbench-skill/results/*edge-${M}*.json /home/aliixh/pinchbench-skill/results/_pre_yarn128k/ 2>/dev/null
  echo "[qwen] $M @128K-YaRN $(date -u +%T)" >> $LOG
  bash scripts/pinchbench_run.sh "$M" >> $LOG 2>&1 || echo "[qwen] $M failed" >> $LOG
  pkill -f 'llama-server' 2>/dev/null; sleep 10
  python3 import_pinchbench.py >> $LOG 2>&1
  python3 -m src.report.build_leaderboard >> $LOG 2>&1
  cp -f leaderboard.html /home/aliixh/edge_leaderboard.html 2>/dev/null
  NEW=$(python3 -c "import json;print(round(json.load(open('results/scored/$M/pinchbench.json'))['score']*100,1))" 2>/dev/null)
  echo "[qwen]   -> $M PinchBench = ${NEW} (128K-YaRN) $(date -u +%T)" >> $LOG
done
echo "[qwen] qwen reruns DONE -> batched $(date -u +%T)" >> $LOG
pkill -f 'llama-server' 2>/dev/null; sleep 6
MODELS=$(python3 scripts/top_models.py 15 | tr '\n' ' ')
python3 run_benchmark.py --models $MODELS --benchmarks pinchbench_clawd ruler simpleqa gpqa_diamond >> $LOG 2>&1
python3 judge_simpleqa.py >> $LOG 2>&1
python3 import_pinchbench.py >> $LOG 2>&1
python3 rescore_all.py >> $LOG 2>&1
python3 -m src.report.build_leaderboard >> $LOG 2>&1
cp -f leaderboard.html /home/aliixh/edge_leaderboard.html 2>/dev/null
echo "[qwen] ALL DONE $(date -u +%T)" >> $LOG
