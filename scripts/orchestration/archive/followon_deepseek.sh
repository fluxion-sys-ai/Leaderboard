#!/usr/bin/env bash
cd /home/ubuntu/edge-intelligence-benchmark
# 1. wait for the full capability grid to finish
until grep -q "FULL GRID DONE" /tmp/chain_grid.log 2>/dev/null; do sleep 30; done
echo "[followon] grid done $(date -u +%T); re-running DeepSeek with 4x token cap"
# 2. clear DeepSeek's truncated cells + regenerate with max_tokens_mult=4
rm -f results/raw/deepseek-r1-distill-qwen-7b/*.jsonl results/scored/deepseek-r1-distill-qwen-7b/*.json
LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892 python3 run_benchmark.py --models deepseek-r1-distill-qwen-7b
# 3. re-score EVERY cell offline (backfills failure_breakdown across the whole grid)
python3 rescore_all.py
echo "[followon] DONE $(date -u +%T)"
