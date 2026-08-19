#!/usr/bin/env bash
# FINAL: after spec pass, run the full grid (fills new models + all 12 benchmarks
# incl BABILong/BFCL/Writing-gen, cache-aware), judge the writing responses, then
# rescore + rebuild the leaderboard.
cd /home/aliixh/edge-intelligence-benchmark
until grep -qE "\[spec\] (DONE|FLAGS)" /tmp/spec.log 2>/dev/null; do sleep 30; done
echo "[final] spec done $(date -u +%T); full grid (new models + BABILong/BFCL/Writing)"
LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892 python3 run_benchmark.py
echo "[final] judging writing responses $(date -u +%T)"
LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892 python3 judge_writing.py
python3 rescore_all.py
python3 -m src.report.build_leaderboard
/home/aliixh/vllm-env/bin/python /tmp/lb_render.py
cp -f leaderboard.html /home/aliixh/edge_leaderboard.html
echo "[final] ALL DONE $(date -u +%T)"
