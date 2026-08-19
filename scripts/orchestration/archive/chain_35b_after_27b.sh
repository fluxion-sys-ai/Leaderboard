#!/bin/bash
set -u
cd /home/aliixh/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/chain_35b.log
echo "[chain] waiting for 27B PinchBench to finish $(date -u +%T)" > $L
# 1) wait for the 27B agent harness to exit (solo-GPU: don't start until it's done)
while pgrep -f "benchmark.py --model openai/edge-qwen3.6-27b" >/dev/null; do sleep 60; done
echo "[chain] 27B done -> import + leaderboard $(date -u +%T)" >> $L
python3 import_pinchbench.py >> $L 2>&1
python3 -m src.report.build_leaderboard >> $L 2>&1
# 2) free GPU, then 35B PinchBench @128K (script already patched to CTX=131072)
pkill -f 'llama-server' 2>/dev/null; sleep 8
echo "[chain] launching 35B PinchBench @128K $(date -u +%T)" >> $L
bash scripts/pinchbench_run.sh qwen3.5-35b-a3b >> $L 2>&1 || echo "[chain] 35B errored" >> $L
pkill -f 'llama-server' 2>/dev/null; sleep 8
echo "[chain] 35B done -> import + final leaderboard $(date -u +%T)" >> $L
python3 import_pinchbench.py >> $L 2>&1
python3 -m src.report.build_leaderboard >> $L 2>&1
echo "[chain] ALL DONE $(date -u +%T)" >> $L
