#!/usr/bin/env bash
# After coding finishes: verify the draft-decode flags actually emit per-position
# acceptance on this llama.cpp build (smoke), and only then run the full spec pass.
cd /home/ubuntu/edge-intelligence-benchmark
until grep -q "\[coding\] DONE" /tmp/coding.log 2>/dev/null; do sleep 30; done
echo "[spec] coding done $(date -u +%T); smoke-testing draft flags"
rm -f results/spec/raw/qwen2.5-7b-instruct/ifeval.jsonl results/spec/scored/qwen2.5-7b-instruct/ifeval.json 2>/dev/null
LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892 timeout 400 python3 run_benchmark.py --spec --models qwen2.5-7b-instruct --benchmarks ifeval --limit 4
if grep -q "acc per pos" /tmp/llamacpp_qwen2.5-7b-instruct.log 2>/dev/null; then
  echo "[spec] flags OK — 'acc per pos' emitted; running full spec pass (ifeval+gsm8k, 5 draft models)"
  LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892 python3 run_benchmark.py --spec --benchmarks ifeval gsm8k
  python3 -m src.report.build_leaderboard
  /home/ubuntu/vllm-env/bin/python /tmp/lb_render.py
  cp -f leaderboard.html /home/ubuntu/edge_leaderboard.html
  echo "[spec] DONE $(date -u +%T) — per-position acceptance now on the board"
else
  echo "[spec] FLAGS NEED FIXING — 'acc per pos' not found in server log; spec pass skipped (data intact, needs manual flag check)"
fi
