#!/bin/bash
# TerminalBench (agentic terminal tasks) for the Frontier tab, full-precision over OpenRouter.
# Uses the terminus-2 agent (Meta's Muse Glimmer methodology) on the official
# terminal-bench-core==0.1.1 dataset. Each task runs in its own Docker container.
#
# Usage: scripts/terminalbench_run.sh <muse|qwen27|qwen35|gemma> [n_tasks]
#   e.g. scripts/terminalbench_run.sh muse 2      # smoke
#        scripts/terminalbench_run.sh muse        # full dataset
set -u
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
export PATH="$HOME/.local/bin:$PATH"
export OPENROUTER_API_KEY="$(cat "$REPO/.openrouter_key")"
KEY="${1:?usage: terminalbench_run.sh <muse|qwen27|qwen35|gemma> [n_tasks]}"
NTASKS="${2:-}"

case "$KEY" in
  muse)   MODEL="openrouter/meta/muse-glimmer-30b" ;;
  gemma)  MODEL="openrouter/google/gemma-4-31b-it" ;;
  qwen27) MODEL="openrouter/qwen/qwen3.6-27b" ;;
  qwen35) MODEL="openrouter/qwen/qwen3.6-35b-a3b" ;;
  *) echo "unknown model key: $KEY"; exit 2 ;;
esac

OUT="$REPO/results/terminalbench/$KEY"
mkdir -p "$OUT"
NARG=(); [ -n "$NTASKS" ] && NARG=(--n-tasks "$NTASKS")

exec tb run \
  --dataset terminal-bench-core==0.1.1 \
  --agent terminus-2 \
  --agent-kwarg temperature=1.0 \
  --model "$MODEL" \
  "${NARG[@]}" \
  --output-path "$OUT" \
  --run-id "$KEY" \
  --n-concurrent 2 \
  --cleanup
