#!/bin/bash
# TerminalBench for the Q4-LOCAL frontier models. Serves the model's Q4 GGUF on a local
# llama-server (OpenAI-compatible) and points terminus-2/litellm at it via OPENAI_API_BASE.
# Recommended sampling + thinking ON — matches the full-precision terminal runs. Muse needs b10433.
#
# ROBUST: a keepalive monitor restarts the llama-server if it dies mid-run (a heavy terminal
# task — e.g. a kernel build in its Docker container — can spike host memory and get the server
# OOM-killed). terminus-2/litellm retries then reconnect. KV footprint kept modest (-c 65536).
#
# Usage: terminalbench_q4_run.sh <gemma|qwen27|qwen35|qwen38|muse> [n_tasks]
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
export PATH="$HOME/.local/bin:$PATH"
PORT=8081
KEY="${1:?usage: terminalbench_q4_run.sh <gemma|qwen27|qwen35|qwen38|muse> [n_tasks]}"
NTASKS="${2:-}"

case "$KEY" in
  gemma)  M=gemma-4-31b-q4f;      SAMP="--temp 1.0 --top-p 0.95 --top-k 64"; TKW='{"enable_thinking":true}'; BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  qwen27) M=qwen3.6-27b-q4f;      SAMP="--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0"; TKW='{"enable_thinking":true}'; BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  qwen35) M=qwen3.5-35b-a3b-q4f;  SAMP="--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 1.5"; TKW='{"enable_thinking":true}'; BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  qwen38) M=qwen3.8-27b-q4f;      SAMP="--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0"; TKW='{"enable_thinking":true}'; BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  muse)   M=muse-glimmer-30b-q4f; SAMP="--temp 1.0 --top-p 0.95 --top-k 64"; TKW='{"reasoning_effort":"high"}'; BIN=/home/aliixh/llama.cpp/llama.cpp-b10433/build/bin ;;
  *) echo "unknown model key: $KEY"; exit 2 ;;
esac

if pgrep -f "llama-server.*--port $PORT" >/dev/null; then echo "!! GPU busy on $PORT"; exit 1; fi
[ -f "$REPO/.hf_token" ] && export HF_TOKEN="$(cat "$REPO/.hf_token")"
GGUF=$(cd "$REPO" && python3 -c "import sys,yaml;sys.path.insert(0,'.');from src.models_fetch import ensure_gguf;m=next(x for x in yaml.safe_load(open('configs/models_q4_frontier.yaml'))['models'] if x['name']=='$M');print(ensure_gguf(m['name'],m['gguf']))")
echo "[tb-q4] $KEY ($M) gguf=$GGUF bin=$(basename $BIN) sampling=$SAMP thinking=$TKW"

SLOG=/tmp/tb_q4_${KEY}_server.log
PIDF=/tmp/tb_q4_${KEY}_server.pid
start_server(){
  # -c 98304 --parallel 2 => 49152 tokens/slot (fits the ~33k-token terminal prompts, no overflow)
  # at the SAME total KV/VRAM as parallel-1, but 2 concurrent requests => ~2x throughput.
  "$BIN/llama-server" -m "$GGUF" -c 98304 --parallel 2 -ngl 999 \
    --chat-template-kwargs "$TKW" $SAMP \
    --host 127.0.0.1 --port $PORT --no-webui >>"$SLOG" 2>&1 &
  echo $! > "$PIDF"
}
start_server
# keepalive: restart the server only after 3 consecutive health failures (~45s) — avoids
# false-restarts when the server is merely busy generating (a transient slow /health).
( fails=0; while true; do
    sleep 15
    if timeout 8 curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
      fails=0
    else
      fails=$((fails+1))
      if [ "$fails" -ge 3 ]; then
        echo "[$(date +%T)] [keepalive] server down (3x) -> restarting" >> "$SLOG"
        kill -9 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
        start_server
        # GRACE: a 27B-Q4 reload often takes >45s; without waiting for it to become healthy the
        # next 3x15s strike window kills a still-loading server -> infinite restart thrash. Wait
        # up to ~90s for /health before resuming strike-counting.
        for _g in $(seq 1 45); do timeout 8 curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 2; done
        fails=0
      fi
    fi
  done ) &
MON=$!
trap 'kill $MON 2>/dev/null; kill -9 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; rm -f "$PIDF"' EXIT
for i in $(seq 1 120); do curl -sf --max-time 8 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 2; done

export OPENAI_API_BASE="http://127.0.0.1:$PORT/v1"
export OPENAI_API_KEY="sk-local"
export TB_MODEL_PARAMS='{"top_p":0.95}'

OUT="$REPO/results/terminalbench_q4/$KEY"
# stale-dir guard: tb refuses to run if the run dir exists without a lock file
[ -d "$OUT/$KEY" ] && [ ! -f "$OUT/$KEY/tb.lock" ] && rm -rf "$OUT/$KEY"
mkdir -p "$OUT"
# Stratified terminal sample: run the SAME fixed 24-task subset (configs/terminal_sample.txt,
# stratified by difficulty, seed 42) for EVERY model to cut wall-clock ~70%. The remaining 56 tasks
# are saved in configs/terminal_sample_remaining.txt to finish later. Falls back to full-80 (or
# --n-tasks N) only if the sample file is absent.
TARGS=()
if [ -s "$REPO/configs/terminal_sample.txt" ]; then
  while IFS= read -r t; do [ -n "$t" ] && TARGS+=(--task-id "$t"); done < "$REPO/configs/terminal_sample.txt"
  echo "[tb-q4] using stratified sample: ${#TARGS[@]} tasks (÷2 = task count)"
elif [ -n "$NTASKS" ]; then TARGS=(--n-tasks "$NTASKS"); fi

cd "$REPO"
# NOT exec: keep the shell so the EXIT trap tears down the server + keepalive when tb finishes.
tb run \
  --dataset terminal-bench-core==0.1.1 \
  --agent terminus-2 \
  --agent-kwarg temperature=1.0 \
  --model "openai/edge-${KEY}-q4" \
  "${TARGS[@]}" \
  --output-path "$OUT" \
  --run-id "$KEY" \
  --n-concurrent 2 \
  --global-agent-timeout-sec 2400 \
  --cleanup
