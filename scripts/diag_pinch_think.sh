#!/bin/bash
# DIAGNOSTIC (throwaway, not a board run): re-run 6 qwen3.8-full PinchBench tasks that scored ~0 under
# no_think, this time with thinking ON (level high) — the vendor-recommended/default mode. If they jump,
# the 42% was a no_think artifact. Writes ONLY to a diag log (per-task scores parsed from stdout); the
# 6-task transcript has category max << 115 so the board's pinch-import gate (tm>=115) can never pick it.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
PB=/home/aliixh/pinchbench-skill
cd "$PB"
export OPENROUTER_API_KEY="$(cat "$REPO/.openrouter_key")"
SUITE="task_csv_cities_ranking,task_csv_gdp_ranking,task_log_apache_error_summary,task_log_hdfs_connections,task_log_mapreduce_failures,task_meeting_council_budget"
echo "[$(date +'%F %T')] DIAG start — qwen3.8 full, thinking=high, 6 no_think-failing tasks" >> "$REPO/logs_diag_pinch_think.log"
uv run scripts/benchmark.py \
  --model openrouter/qwen/qwen3.8-27b --thinking high \
  --judge "openrouter/deepseek/deepseek-chat-v3.1" \
  --suite "$SUITE" >> "$REPO/logs_diag_pinch_think.log" 2>&1
echo "[$(date +'%F %T')] DIAG DONE" >> "$REPO/logs_diag_pinch_think.log"
