#!/bin/bash
# TerminalBench for the Q4-LOCAL frontier models. Serves the model's Q4 GGUF on a local
# llama-server (OpenAI-compatible) and points terminus-2/litellm at it via OPENAI_API_BASE.
# Recommended sampling + thinking ON — matches the full-precision terminal runs (which used
# reasoning high / think ON). Muse needs llama.cpp b10433; the rest use b9892.
# Each task still runs in its own Docker container; the agent (litellm) calls localhost:8081.
#
# Usage: terminalbench_q4_run.sh <gemma|qwen27|qwen35|qwen38|muse> [n_tasks]
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
export PATH="$HOME/.local/bin:$PATH"
PORT=8081
KEY="${1:?usage: terminalbench_q4_run.sh <gemma|qwen27|qwen35|qwen38|muse> [n_tasks]}"
NTASKS="${2:-}"

# q4f model name (in models_q4_frontier.yaml) + recommended sampling + thinking kwargs + llama bin
case "$KEY" in
  gemma)  M=gemma-4-31b-q4f;      SAMP="--temp 1.0 --top-p 0.95 --top-k 64"; TKW='{"enable_thinking":true}'; BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  qwen27) M=qwen3.6-27b-q4f;      SAMP="--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0"; TKW='{"enable_thinking":true}'; BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  qwen35) M=qwen3.5-35b-a3b-q4f;  SAMP="--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 1.5"; TKW='{"enable_thinking":true}'; BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  qwen38) M=qwen3.8-27b-q4f;      SAMP="--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0"; TKW='{"enable_thinking":true}'; BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  muse)   M=muse-glimmer-30b-q4f; SAMP="--temp 1.0 --top-p 0.95 --top-k 64"; TKW='{"reasoning_effort":"high"}'; BIN=/home/aliixh/llama.cpp/llama.cpp-b10433/build/bin ;;
  *) echo "unknown model key: $KEY"; exit 2 ;;
esac

# solo-GPU guard
if pgrep -f "llama-server.*--port $PORT" >/dev/null; then echo "!! GPU busy on $PORT"; exit 1; fi

[ -f "$REPO/.hf_token" ] && export HF_TOKEN="$(cat "$REPO/.hf_token")"
GGUF=$(cd "$REPO" && python3 -c "import sys,yaml;sys.path.insert(0,'.');from src.models_fetch import ensure_gguf;m=next(x for x in yaml.safe_load(open('configs/models_q4_frontier.yaml'))['models'] if x['name']=='$M');print(ensure_gguf(m['name'],m['gguf']))")
echo "[tb-q4] $KEY ($M) gguf=$GGUF bin=$(basename $BIN) sampling=$SAMP thinking=$TKW"

"$BIN/llama-server" -m "$GGUF" -c 98304 --parallel 2 -ngl 999 \
  --chat-template-kwargs "$TKW" $SAMP \
  --host 127.0.0.1 --port $PORT --no-webui >/tmp/tb_q4_${KEY}_server.log 2>&1 &
LP=$!; trap "kill $LP 2>/dev/null || true" EXIT
for i in $(seq 1 120); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 2; done

# route litellm/terminus-2 at the local server
export OPENAI_API_BASE="http://127.0.0.1:$PORT/v1"
export OPENAI_API_KEY="sk-local"
# sampling params (no OpenRouter provider pin — local); temperature via --agent-kwarg
export TB_MODEL_PARAMS='{"top_p":0.95}'

OUT="$REPO/results/terminalbench_q4/$KEY"
mkdir -p "$OUT"
NARG=(); [ -n "$NTASKS" ] && NARG=(--n-tasks "$NTASKS")

cd "$REPO"
# NOT exec: keep the shell so the EXIT trap kills the llama-server when tb finishes
# (otherwise the next queued model hits the solo-GPU guard).
tb run \
  --dataset terminal-bench-core==0.1.1 \
  --agent terminus-2 \
  --agent-kwarg temperature=1.0 \
  --model "openai/edge-${KEY}-q4" \
  "${NARG[@]}" \
  --output-path "$OUT" \
  --run-id "$KEY" \
  --n-concurrent 2 \
  --cleanup
