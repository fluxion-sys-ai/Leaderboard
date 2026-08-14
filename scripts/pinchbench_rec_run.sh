#!/usr/bin/env bash
# PinchBench at RECOMMENDED sampling + no_think, for the frontier Q4 GGUFs.
# thinking-ON zeroes this agentic benchmark (agent burns its turn reasoning), so no_think is
# REQUIRED by the harness — the only "rec" lever left is sampling: temp 1.0 / top_p 0.95 / top_k
# (+ min_p/presence for Qwen), set server-side. Local GPU, solo. Muse Q4 is blocked (no arch).
#
# Usage: pinchbench_rec_run.sh <gemma|qwen27|qwen35> [n_tasks]   (n_tasks omitted = full 116)
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
PB=/home/aliixh/pinchbench-skill
PORT=8081
KEY="${1:?usage: pinchbench_rec_run.sh <gemma|qwen27|qwen35> [n_tasks]}"
NTASKS="${2:-}"

# GGUF model name (greedy-board name = the frontier Q4 GGUF) + recommended sampling (FRONTIER_SPEC)
case "$KEY" in
  gemma)  MODEL=gemma-4-31b;     SAMP="--temp 1.0 --top-p 0.95 --top-k 64" ;;
  qwen27) MODEL=qwen3.6-27b;     SAMP="--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0" ;;
  qwen35) MODEL=qwen3.5-35b-a3b; SAMP="--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 1.5" ;;
  *) echo "unknown key: $KEY"; exit 2 ;;
esac

# solo-GPU guard: never run alongside another llama-server
if pgrep -f "llama-server.*--port $PORT" >/dev/null; then
  echo "!! GPU busy (llama-server on $PORT). Aborting pinchbench-rec."; exit 1
fi

GGUF=$(python3 -c "import sys,yaml;sys.path.insert(0,'$REPO');from src.models_fetch import ensure_gguf;m=next(x for x in yaml.safe_load(open('$REPO/configs/models.yaml'))['models'] if x['name']=='$MODEL');print(ensure_gguf(m['name'],m['gguf']))")
echo "[pb-rec] $KEY ($MODEL) gguf=$GGUF sampling=$SAMP no_think=yes"

# no_think (thinking-ON = 0% here) + REC sampling, 128K ctx (gemma-4/qwen 128-256K native)
/home/aliixh/llama.cpp/llama-b9892/llama-server -m "$GGUF" -c 131072 --parallel 1 -ngl 999 \
  --chat-template-kwargs '{"enable_thinking":false}' $SAMP \
  --host 127.0.0.1 --port $PORT --no-webui >/tmp/pb_rec_${MODEL}.log 2>&1 &
LP=$!; trap "kill $LP 2>/dev/null || true" EXIT
for i in $(seq 1 120); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 2; done

export OPENROUTER_API_KEY="$(cat "$REPO/.openrouter_key")"
cd "$PB"
if [ -n "$NTASKS" ]; then SUITE=$(head -"$NTASKS" "$REPO/configs/pinchbench_tasks.txt" | paste -sd,)
else SUITE=$(paste -sd, "$REPO/configs/pinchbench_tasks.txt"); fi
uv run scripts/benchmark.py \
  --model "openai/edge-${MODEL}-recparam" \
  --base-url "http://127.0.0.1:$PORT/v1" \
  --judge "openrouter/deepseek/deepseek-chat-v3.1" \
  --suite "$SUITE"
