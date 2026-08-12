#!/bin/bash
# tau3-banking (τ³-Bench, banking_knowledge domain) over OpenRouter — the
# "general agentic" benchmark from Meta's Muse Glimmer methodology.
#
# Everything runs on the OpenRouter key (agent + user-simulator + KB embeddings),
# with the model's precision pin applied via LiteLLM extra_body. No Docker/web.
#
# Usage:  scripts/tau3_banking_run.sh <muse|qwen27|qwen35|gemma> [num_tasks] [num_trials]
#   e.g.  scripts/tau3_banking_run.sh muse 20 1
#
# Prereqs (one-time): tau2-bench cloned at ~/tau2-bench, `pip install -e .`,
#   `pip install rank_bm25`. KB embeddings cache warms on first run.
set -euo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
TAU2=/home/aliixh/tau2-bench
MODEL_KEY="${1:?usage: tau3_banking_run.sh <muse|qwen27|qwen35|gemma> [num_tasks] [num_trials]}"
NUM_TASKS="${2:-20}"
NUM_TRIALS="${3:-1}"           # AA reports pass^k — bump for stochastic averaging

# Per-model slug + sampling + precision pin (from configs/models_full.yaml).
# Recommended sampling verbatim; extra_body.provider = the bf16/fp8 pin.
case "$MODEL_KEY" in
  muse)   SLUG="openrouter/meta/muse-glimmer-30b"
          ARGS='{"temperature":1.0,"top_p":0.95,"extra_body":{"provider":{"quantizations":["bf16"],"order":["DeepInfra"],"allow_fallbacks":false}}}' ;;
  gemma)  SLUG="openrouter/google/gemma-4-31b-it"
          ARGS='{"temperature":1.0,"top_p":0.95,"extra_body":{"provider":{"quantizations":["bf16"],"order":["OpenInference","CoreWeave","Novita"],"allow_fallbacks":true}}}' ;;
  qwen27) SLUG="openrouter/qwen/qwen3.6-27b"
          ARGS='{"temperature":1.0,"top_p":0.95,"presence_penalty":0.0,"extra_body":{"provider":{"quantizations":["fp8"],"allow_fallbacks":true}}}' ;;
  qwen35) SLUG="openrouter/qwen/qwen3.6-35b-a3b"
          ARGS='{"temperature":1.0,"top_p":0.95,"presence_penalty":1.5,"extra_body":{"provider":{"quantizations":["fp8"],"allow_fallbacks":true}}}' ;;
  *) echo "unknown model key: $MODEL_KEY"; exit 2 ;;
esac

export OPENROUTER_API_KEY="$(cat "$REPO/.openrouter_key")"
OUT="$REPO/results/tau3_banking/$MODEL_KEY"
mkdir -p "$OUT"

cd "$TAU2"
exec tau2 run \
  --domain banking_knowledge --retrieval-config qwen_embeddings \
  --agent-llm "$SLUG" --agent-llm-args "$ARGS" \
  --user-llm openrouter/deepseek/deepseek-chat-v3.1 --user-llm-args '{"temperature":0.0}' \
  --num-tasks "$NUM_TASKS" --num-trials "$NUM_TRIALS" \
  --max-concurrency 2 --max-steps 40 \
  --save-to "$OUT"
