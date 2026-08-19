#!/usr/bin/env bash
# Wait for the running IFEval column to finish, then run the full capability grid
# (all built benchmarks × all 7 models). Resumable — skips cached cells.
cd /home/aliixh/edge-intelligence-benchmark
IFEVAL_PID=1273062
while kill -0 "$IFEVAL_PID" 2>/dev/null; do sleep 30; done
echo "[chain] IFEval column done; starting full grid $(date -u +%T)"
LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892 python3 run_benchmark.py
echo "[chain] FULL GRID DONE $(date -u +%T)"
