#!/bin/bash
# PinchBench on the FULL-PRECISION models via OpenRouter (no GPU). Thinking = OFF for PinchBench:
# it's an agentic multi-turn benchmark and thinking ZEROES the agent (the model reasons instead of
# acting), a finding baked into the board ("OFF — thinking zeroes agentic"). PROOF: qwen3.8 full pinch
# scored 0.833 with Thinking:off; the --thinking high variant was an untested regression that would
# either zero the other 4 or make them non-comparable to qwen3.8. Sampling still uses the vendor rec
# (top_p/top_k/min_p/presence via models_full.yaml) — only the reasoning trace is off. Judge = deepseek.
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
  claude) MODEL="openrouter/anthropic/claude-sonnet-5" ;;
  *) echo "unknown key: $KEY"; exit 2 ;;
esac
# qwen3.8-FIRST phase: while this flag exists, ONLY qwen38 pinch runs; the other 4 are deferred so
# qwen3.8 can finish its full pipeline (pinch->terminal->swe) before them. other4_pinch_queue clears it.
if [ "$KEY" != "qwen38" ] && [ -f "$REPO/.QWEN38_ONLY_PHASE" ]; then
  echo "[pb-full] .QWEN38_ONLY_PHASE set — deferring $KEY (qwen3.8 pipeline runs first)"; exit 0
fi
export OPENROUTER_API_KEY="$(cat "$REPO/.openrouter_key")"
# Inject per-model VENDOR-REC sampling (top_p/top_k/min_p/presence) + precision pin: lib_agent.py
# reads this config, matches --model's slug, and packages the sampling into the agent's provider
# params. Without it, full pinch runs at OpenRouter DEFAULTS (top_p 1.0, no top_k) — NOT rec.
export PINCHBENCH_MODELS_FULL="$REPO/configs/models_full.yaml"
cd "$PB"
if [ -n "$NTASKS" ]; then SUITE=$(head -"$NTASKS" "$REPO/configs/pinchbench_tasks.txt" | paste -sd,)
else SUITE=$(paste -sd, "$REPO/configs/pinchbench_tasks.txt"); fi
exec uv run scripts/benchmark.py \
  --model "$MODEL" --thinking off \
  --judge "openrouter/deepseek/deepseek-chat-v3.1" \
  --suite "$SUITE"
