#!/bin/bash
# Remaining batched benchmarks (RULER/SimpleQA/GPQA) on the ~5 unfinished models
# (cache-aware) + SimpleQA judge + rescore + rebuild. No PinchBench reruns (granite kept
# @128K=32.8; qwen2.5/qwen3 stay @32K — 128K unreachable on this GGUF).
set -u
cd /home/aliixh/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"; export LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892
LOG=/tmp/batched_only.log
echo "[batched] START $(date -u +%T)" > $LOG
MODELS=$(python3 scripts/top_models.py 15 | tr '\n' ' ')
python3 run_benchmark.py --models $MODELS --benchmarks ruler simpleqa gpqa_diamond >> $LOG 2>&1
python3 judge_simpleqa.py >> $LOG 2>&1
python3 rescore_all.py >> $LOG 2>&1
python3 -m src.report.build_leaderboard >> $LOG 2>&1
cp -f leaderboard.html /home/aliixh/edge_leaderboard.html 2>/dev/null
echo "[batched] ALL DONE $(date -u +%T)" >> $LOG
