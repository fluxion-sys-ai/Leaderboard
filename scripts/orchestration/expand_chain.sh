#!/usr/bin/env bash
# After the capability grid finishes: fix DeepSeek (truncation), expand every cell
# to the new sample size (ADDITIVE — keeps prior prompts, no repeats), re-score all,
# rebuild + render the leaderboard.
cd /home/ubuntu/edge-intelligence-benchmark
until grep -q "FULL GRID DONE" /tmp/chain_grid.log 2>/dev/null; do sleep 30; done
echo "[expand] grid done $(date -u +%T)"
# DeepSeek's cells were truncated at 1024 -> regenerate fresh at 4x tokens
rm -f results/raw/deepseek-r1-distill-qwen-7b/*.jsonl results/scored/deepseek-r1-distill-qwen-7b/*.json
# Expand all models to the new sample sizes (additive via cache-aware run_cell)
LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892 python3 run_benchmark.py
echo "[expand] grid @300 done $(date -u +%T); rescoring + rebuilding leaderboard"
python3 rescore_all.py
python3 -m src.report.build_leaderboard
/home/ubuntu/vllm-env/bin/python /tmp/lb_render.py
cp -f leaderboard.html /home/ubuntu/edge_leaderboard.html
echo "[expand] DONE $(date -u +%T)"
