#!/bin/bash
# granite PinchBench catch-up. granite was skipped at the smoke->loop transition
# (qwen2.5's server wasn't killed before granite's turn -> solo-GPU guard aborted).
# Waits for the whole pipeline to finish + GPU free, then runs granite PinchBench.
set -u
cd /home/aliixh/edge-intelligence-benchmark
LOG=/tmp/granite_catchup.log
echo "[granite-catchup] armed, waiting for pipeline+GPU $(date -u +%T)" > $LOG
while pgrep -f 'pinchbench_first_run.sh' >/dev/null || pgrep -f 'llama-b9892/llama-server' >/dev/null; do sleep 120; done
echo "[granite-catchup] GPU free -> granite PinchBench $(date -u +%T)" >> $LOG
pkill -f 'llama-server' 2>/dev/null; sleep 6
bash scripts/pinchbench_run.sh granite-4.1-8b >> $LOG 2>&1 || echo "[granite-catchup] run errored" >> $LOG
pkill -f 'llama-server' 2>/dev/null; sleep 10
python3 import_pinchbench.py >> $LOG 2>&1
python3 -m src.report.build_leaderboard >> $LOG 2>&1
cp -f leaderboard.html /home/aliixh/edge_leaderboard.html 2>/dev/null
echo "[granite-catchup] DONE $(date -u +%T)" >> $LOG
