#!/bin/bash
# Un-deferred Qwen3.5-9B + Qwen3.5-4B base models (no-think mode). Runs AFTER the 35B/27B
# finish: full grid + PinchBench + judges + rebuild. Same no-think fix — they're the same
# Qwen3.5 thinking family, just deferred earlier (not broken).
set -u
cd /home/aliixh/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"; export LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
LOG=/tmp/qwen35_base_run.log
BENCH="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl simpleqa"
echo "[q35] waiting for the 35B/27B run + GPU free $(date -u +%T)" > $LOG
while pgrep -f 'bash /tmp/newmodels_run.sh' >/dev/null || pgrep -f 'llama-b9892/llama-server' >/dev/null; do sleep 120; done
echo "[q35] GPU free -> running qwen3.5-9b + qwen3.5-4b (no-think) $(date -u +%T)" >> $LOG
for M in qwen3.5-9b qwen3.5-4b; do
  pkill -f 'llama-server' 2>/dev/null; sleep 6
  echo "[q35] ===== $M grid $(date -u +%T) =====" >> $LOG
  python3 run_benchmark.py --models "$M" --benchmarks $BENCH >> $LOG 2>&1 || echo "[q35] $M grid errored" >> $LOG
  if ls results/scored/$M/*.json >/dev/null 2>&1; then
    pkill -f 'llama-server' 2>/dev/null; sleep 6
    echo "[q35] $M PinchBench $(date -u +%T)" >> $LOG
    bash scripts/pinchbench_run.sh "$M" >> $LOG 2>&1 || echo "[q35] $M pinchbench errored" >> $LOG
    pkill -f 'llama-server' 2>/dev/null; sleep 8
    python3 import_pinchbench.py >> $LOG 2>&1
  else echo "[q35] !! $M no scores — failed to load, skipping" >> $LOG; fi
  python3 -m src.report.build_leaderboard >> $LOG 2>&1
done
echo "[q35] judges + rebuild $(date -u +%T)" >> $LOG
python3 judge_writing.py >> $LOG 2>&1; python3 judge_simpleqa.py >> $LOG 2>&1
python3 rescore_all.py >> $LOG 2>&1; python3 -m src.report.build_leaderboard >> $LOG 2>&1
cp -f leaderboard.html /home/aliixh/edge_leaderboard.html 2>/dev/null
echo "[q35] ALL DONE $(date -u +%T)" >> $LOG
