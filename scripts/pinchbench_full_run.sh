#!/bin/bash
# PinchBench on the FULL-PRECISION models via OpenRouter (no GPU). --thinking off, because
# thinking-ON zeroes this agentic benchmark (agent burns its turn reasoning). Judge = deepseek.
# Usage: pinchbench_full_run.sh <muse|qwen27|qwen35|gemma> [n_tasks]   (omit n_tasks = full 116)
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
PB=/home/aliixh/pinchbench-skill
KEY="${1:?usage: pinchbench_full_run.sh <muse|qwen27|qwen35|gemma> [n_tasks]}"
NTASKS="${2:-}"
case "$KEY" in
  muse)   MODEL="openrouter/meta/muse-glimmer-30b" ;;
  qwen27) MODEL="openrouter/qwen/qwen3.6-27b" ;;
  qwen35) MODEL="openrouter/qwen/qwen3.6-35b-a3b" ;;
  gemma)  MODEL="openrouter/google/gemma-4-31b-it" ;;
  qwen38) MODEL="openrouter/qwen/qwen3.8-27b" ;;
  *) echo "unknown key: $KEY"; exit 2 ;;
esac
export OPENROUTER_API_KEY="$(cat "$REPO/.openrouter_key")"
cd "$PB"
if [ -n "$NTASKS" ]; then SUITE=$(head -"$NTASKS" "$REPO/configs/pinchbench_tasks.txt" | paste -sd,)
else SUITE=$(paste -sd, "$REPO/configs/pinchbench_tasks.txt"); fi
exec uv run scripts/benchmark.py \
  --model "$MODEL" --thinking off \
  --judge "openrouter/deepseek/deepseek-chat-v3.1" \
  --suite "$SUITE"
