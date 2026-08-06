#!/usr/bin/env bash
cd /home/ubuntu/edge-intelligence-benchmark
until grep -q "\[expand\] DONE" /tmp/expand.log 2>/dev/null; do sleep 30; done
echo "[coding] expansion done $(date -u +%T); running HumanEval+ & LiveCodeBench on all models"
LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892 python3 run_benchmark.py --benchmarks humaneval livecodebench
python3 rescore_all.py
python3 -m src.report.build_leaderboard
/home/ubuntu/vllm-env/bin/python /tmp/lb_render.py
cp -f leaderboard.html /home/ubuntu/edge_leaderboard.html
echo "[coding] DONE $(date -u +%T)"
