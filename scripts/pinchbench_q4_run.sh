#!/bin/bash
# PinchBench Q4-LOCAL via the 'edgelocal' OpenClaw provider (registered in openclaw.json).
# Serves the model's Q4 GGUF on :8081 + recommended sampling; the pinch OpenClaw agent resolves
# edgelocal/edge-<key>-q4 -> :8081. Thinking = OFF for Q4-LOCAL: thinking-ON was tried (to match the
# vendor rec) but MEASURED to make this Q4 model emit 2000+ tokens of reasoning with zero answer, so
# the agentic harness timed out with no transcript and every Q4 pinch scored 0. Thinking-off yields a
# real answer fast (see server-launch comment below). Full-precision pinch keeps thinking-ON (OpenRouter,
# fast enough). deepseek-chat-v3.1 judge over OpenRouter. Muse needs b10433.
#
# Usage: pinchbench_q4_run.sh <gemma|qwen27|qwen35|qwen38|muse> [n_tasks]   (omit n_tasks = full 116)
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
PB=/home/aliixh/pinchbench-skill
PORT=8081
KEY="${1:?usage: pinchbench_q4_run.sh <gemma|qwen27|qwen35|qwen38|muse> [n_tasks]}"
NTASKS="${2:-}"

# q4f GGUF name + RECOMMENDED sampling (no_think) + llama bin
case "$KEY" in
  gemma)  M=gemma-4-31b-q4f;      SAMP="--temp 1.0 --top-p 0.95 --top-k 64"; BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  # pinch runs thinking-OFF -> use the HF NON-THINKING recipe (complete set matched to the mode):
  # dense Qwen (27B/3.8) = temp 0.7 / top_p 0.80 / top_k 20 / min_p 0 / presence 1.5 (was wrongly on
  # the thinking-mode set temp1.0/0.95/pp0.0). MoE 35B non-thinking keeps temp1.0/0.95/pp1.5.
  qwen27) M=qwen3.6-27b-q4f;      SAMP="--temp 0.7 --top-p 0.80 --top-k 20 --min-p 0 --presence-penalty 1.5 --repeat-penalty 1.0"; BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  qwen35) M=qwen3.5-35b-a3b-q4f;  SAMP="--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 1.5"; BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  qwen38) M=qwen3.8-27b-q4f;      SAMP="--temp 0.7 --top-p 0.80 --top-k 20 --min-p 0 --presence-penalty 1.5 --repeat-penalty 1.0"; BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  muse)   M=muse-glimmer-30b-q4f; SAMP="--temp 1.0 --top-p 0.95 --top-k 64"; BIN=/home/aliixh/llama.cpp/llama.cpp-b10433/build/bin ;;
  *) echo "unknown model key: $KEY"; exit 2 ;;
esac

if pgrep -f "llama-server.*--port $PORT" >/dev/null; then echo "!! GPU busy on $PORT"; exit 1; fi
[ -f "$REPO/.hf_token" ] && export HF_TOKEN="$(cat "$REPO/.hf_token")"
GGUF=$(cd "$REPO" && python3 -c "import sys,yaml;sys.path.insert(0,'.');from src.models_fetch import ensure_gguf;m=next(x for x in yaml.safe_load(open('configs/models_q4_frontier.yaml'))['models'] if x['name']=='$M');print(ensure_gguf(m['name'],m['gguf']))")
echo "[pb-q4] $KEY ($M) gguf=$GGUF bin=$(basename $BIN) no_think sampling=$SAMP"

# thinking OFF for Q4-LOCAL pinch. MEASURED: with enable_thinking:true this Q4 model emits 2000+
# tokens of pure reasoning_content and ZERO answer content (finish_reason=length before it ever
# stops thinking, ~44 tok/s), so the agentic pinch harness never gets a usable first turn -> the
# task times out at ~98s with no transcript -> every Q4 pinch scored 0. Thinking-off returns a real
# 3.6k-char answer in ~23s. A real thinking-off number beats a permanent zero. (Full-precision pinch
# stays thinking-ON via OpenRouter, which is fast enough to finish.) --parallel 2 for a little
# headroom; pinch is single-stream so this is just robustness.
"$BIN/llama-server" -m "$GGUF" -c 131072 --parallel 2 -ngl 999 \
  --chat-template-kwargs '{"enable_thinking":false}' $SAMP \
  --host 127.0.0.1 --port $PORT --no-webui >/tmp/pb_q4_${KEY}_server.log 2>&1 &
LP=$!; trap "kill $LP 2>/dev/null || true" EXIT
for i in $(seq 1 120); do curl -sf --max-time 8 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 2; done

export OPENROUTER_API_KEY="$(cat "$REPO/.openrouter_key")"   # deepseek judge
cd "$PB"
if [ -n "$NTASKS" ]; then SUITE=$(head -"$NTASKS" "$REPO/configs/pinchbench_tasks.txt" | paste -sd,)
else SUITE=$(paste -sd, "$REPO/configs/pinchbench_tasks.txt"); fi
uv run scripts/benchmark.py \
  --model "edgelocal/edge-${KEY}-q4" --thinking off \
  --judge "openrouter/deepseek/deepseek-chat-v3.1" \
  --suite "$SUITE"
