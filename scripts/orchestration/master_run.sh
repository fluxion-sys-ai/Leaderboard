#!/usr/bin/env bash
cd /home/ubuntu/edge-intelligence-benchmark
export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
echo "[master] full grid start $(date -u +%T)"
python3 run_benchmark.py                                   # resilient + cache-aware: fills every gap
echo "[master] writing judge $(date -u +%T)"
python3 judge_writing.py
echo "[master] spec smoke-check $(date -u +%T)"
rm -f results/spec/raw/qwen2.5-7b-instruct/ifeval.jsonl results/spec/scored/qwen2.5-7b-instruct/ifeval.json 2>/dev/null
timeout 500 python3 run_benchmark.py --spec --models qwen2.5-7b-instruct --benchmarks ifeval --limit 4
if grep -q "acc per pos" /tmp/llamacpp_qwen2.5-7b-instruct.log 2>/dev/null; then
  echo "[master] spec flags OK -> full spec pass"
  python3 run_benchmark.py --spec --benchmarks ifeval gsm8k
else
  echo "[master] spec flags failed -> skipped (data intact)"
fi
echo "[master] rescore + leaderboard $(date -u +%T)"
python3 rescore_all.py
python3 -m src.report.build_leaderboard
/home/ubuntu/vllm-env/bin/python /tmp/lb_render.py
cp -f leaderboard.html /home/ubuntu/edge_leaderboard.html
echo "[master] ALL DONE $(date -u +%T)"
