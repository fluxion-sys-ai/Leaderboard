#!/bin/bash
# CORRECTIVE re-run: Phase 2 batched benchmarks failed for all 15 models because
# LLAMACPP_BIN wasn't exported (run_benchmark defaulted to /home/ubuntu/llama.cpp,
# but the b9892 binary lives in .../llama-b9892/). Set it, re-run the 4 new-dimension
# benchmarks (cache-aware: qwen2.5 already has them, only the other 14 generate),
# then re-judge SimpleQA + rescore + rebuild. Waits for granite catch-up + GPU free first.
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
export HF_TOKEN="$(cat .hf_token)"
LOG=/tmp/batched_fix.log
echo "[batched-fix] waiting for granite catch-up + GPU free $(date -u +%T)" > $LOG
while pgrep -f 'granite_catchup.sh' >/dev/null || pgrep -f 'llama-b9892/llama-server' >/dev/null; do sleep 120; done
echo "[batched-fix] GPU free -> batched benchmarks $(date -u +%T)" >> $LOG
pkill -f 'llama-server' 2>/dev/null; sleep 6
MODELS=$(python3 scripts/top_models.py 15 | tr '\n' ' ')
echo "[batched-fix] models: $MODELS" >> $LOG
python3 run_benchmark.py --models $MODELS --benchmarks pinchbench_clawd ruler simpleqa gpqa_diamond >> $LOG 2>&1
echo "[batched-fix] gen done -> judge + rescore + build $(date -u +%T)" >> $LOG
python3 judge_simpleqa.py >> $LOG 2>&1
python3 import_pinchbench.py >> $LOG 2>&1
python3 rescore_all.py >> $LOG 2>&1
python3 -m src.report.build_leaderboard >> $LOG 2>&1
cp -f leaderboard.html /home/ubuntu/edge_leaderboard.html 2>/dev/null
echo "[batched-fix] ALL DONE $(date -u +%T)" >> $LOG
