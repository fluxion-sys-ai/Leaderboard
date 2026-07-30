#!/usr/bin/env bash
# Runs PinchBench (agentic personal-task benchmark) against ONE of our edge models
# via its local llama.cpp OpenAI-compatible endpoint. Uses DeepSeek-Chat-v3.1 via
# OpenRouter as the judge (same key as the writing benchmark). SOLO-GPU SAFE —
# refuses to launch if a llama-server is already running.
#
# Usage: pinchbench_run.sh <model-name-from-models.yaml>
#   e.g. pinchbench_run.sh qwen2.5-7b-instruct
#
# Results go to /home/ubuntu/pinchbench-skill/results/edge-<model>-*.json to keep
# them clearly separated from prior gemma/qwen custom runs.
set -euo pipefail
MODEL="${1:?pass a model name from configs/models.yaml}"
shift   # consume the model name so it isn't re-passed to benchmark.py via "$@"
REPO=/home/ubuntu/edge-intelligence-benchmark
PB=/home/ubuntu/pinchbench-skill
PORT=8081

# solo-GPU rule: refuse to run alongside the main grid
if pgrep -f 'llama-server.*--port '"$PORT" >/dev/null; then
  echo "!! llama-server already running on port $PORT (main grid still active). Aborting."
  exit 1
fi

# resolve the GGUF path via the existing fetcher, then start a dedicated server
GGUF=$(python3 -c "
import sys, yaml
sys.path.insert(0,'$REPO')
from src.models_fetch import ensure_gguf
m=next(x for x in yaml.safe_load(open('$REPO/configs/models.yaml'))['models'] if x['name']=='$MODEL')
print(ensure_gguf(m['name'], m['gguf']))
")
# PinchBench context: the OpenClaw agent's system prompt + skills alone is ~19K
# tokens, so 20480 (the main-grid default) left almost no room for task files and
# ~76% of tasks failed with "context overflow" — a config artifact, not model
# quality. Give each request 32768 (native for granite/glm/qwen2.5/qwen3/mistral,
# so no rope/yarn degradation); gemma-2-9b-it is 8K-native so cap it there rather
# than force-extend. --parallel 1 = one sequential slot (PinchBench runs one task
# at a time) so the FULL context goes to each request instead of being shared.
CTX=32768
[ "$MODEL" = "gemma-2-9b-it" ] && CTX=8192
echo "[pb] model=$MODEL gguf=$GGUF ctx=$CTX"

# start the llama-server
/home/ubuntu/llama.cpp/llama-b9892/llama-server \
  -m "$GGUF" -c "$CTX" --parallel 1 -ngl 999 --host 127.0.0.1 --port $PORT --no-webui \
  >/tmp/pb_llama_${MODEL}.log 2>&1 &
LP=$!
trap "kill $LP 2>/dev/null || true" EXIT

# wait for /health to come up
for i in $(seq 1 120); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
  sleep 2
done

# supply the judge key (deepseek via OpenRouter) — same as our writing judge
export OPENROUTER_API_KEY="$(cat "$REPO/.openrouter_key")"

cd "$PB"
# Pinned 116-task suite (shujun's list). Comma-join the task file into --suite.
SUITE=$(paste -sd, "$REPO/configs/pinchbench_tasks.txt")
# --base-url points at our local endpoint; PinchBench skips OpenRouter validation.
# --judge uses the same key. --model is the tag prefix + our model name.
uv run scripts/benchmark.py \
  --model "openai/edge-$MODEL" \
  --base-url "http://127.0.0.1:$PORT/v1" \
  --judge "openrouter/deepseek/deepseek-chat-v3.1" \
  --suite "$SUITE" \
  "$@"
