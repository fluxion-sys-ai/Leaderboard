#!/bin/bash
# Add Qwen3.5-35B-A3B + Qwen3.6-27B across ALL benchmarks + PinchBench (stakeholder req).
# 35B first (well-supported); 27B load-tested — if its Gated-DeltaNet arch won't load on
# b9892, run_benchmark fails fast, produces no scores, and we skip its PinchBench.
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"; export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
LOG=/tmp/newmodels_run.log
BENCH="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl simpleqa"
echo "[new] START $(date -u +%T)" > $LOG
for M in qwen3.5-35b-a3b qwen3.6-27b; do
  echo "[new] ===== $M : downloading + full grid $(date -u +%T) =====" >> $LOG
  pkill -f 'llama-server' 2>/dev/null; sleep 6
  python3 run_benchmark.py --models "$M" --benchmarks $BENCH >> $LOG 2>&1 || echo "[new] $M grid errored" >> $LOG
  if ls results/scored/$M/*.json >/dev/null 2>&1; then
    echo "[new] $M loaded OK -> PinchBench $(date -u +%T)" >> $LOG
    pkill -f 'llama-server' 2>/dev/null; sleep 6
    bash scripts/pinchbench_run.sh "$M" >> $LOG 2>&1 || echo "[new] $M pinchbench errored" >> $LOG
    pkill -f 'llama-server' 2>/dev/null; sleep 8
    python3 import_pinchbench.py >> $LOG 2>&1
  else
    echo "[new] !! $M produced NO scores — likely failed to load (arch). skipping." >> $LOG
  fi
  python3 -m src.report.build_leaderboard >> $LOG 2>&1
done
echo "[new] judges + rescore + final build $(date -u +%T)" >> $LOG
python3 judge_writing.py  >> $LOG 2>&1
python3 judge_simpleqa.py >> $LOG 2>&1
python3 rescore_all.py    >> $LOG 2>&1
python3 -m src.report.build_leaderboard >> $LOG 2>&1
cp -f leaderboard.html /home/ubuntu/edge_leaderboard.html 2>/dev/null
echo "[new] ALL DONE $(date -u +%T)" >> $LOG
