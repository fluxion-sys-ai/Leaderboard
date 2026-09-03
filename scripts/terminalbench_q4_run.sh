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
  # -c 147456 --parallel 3 => 49152 tokens/slot (SAME per-slot ctx as before -> still fits the ~33k-token
  # terminal prompts, no overflow), but 3 concurrent requests => ~1.5x throughput. GPU is bursty (idle
  # gaps during in-container command execution), so extra slots fill the gaps. VRAM: 3 slots ~28GB < 41GB.
  "$BIN/llama-server" -m "$GGUF" -c 147456 --parallel 3 -ngl 999 \
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
# GPU lock: claim the single GPU so the watchdog/q4 queue can't steal it mid-run (gpu_guardian
# releases it if we die). Trap releases it on exit only if we still own it.
GPULOCK=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark/.gpu_lock
trap 'kill $MON 2>/dev/null; kill -9 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; rm -f "$PIDF"; [ "$(cut -f1 "$GPULOCK" 2>/dev/null)" = "$$" ] && rm -f "$GPULOCK"' EXIT
printf '%s\t%s\t\n' "$$" "tb-q4-${KEY}" > "$GPULOCK"
for i in $(seq 1 120); do curl -sf --max-time 8 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 2; done

export OPENAI_API_BASE="http://127.0.0.1:$PORT/v1"
export OPENAI_API_KEY="sk-local"
export TB_MODEL_PARAMS='{"top_p":0.95}'

OUT="${TB_OUT:-$REPO/results/terminalbench_q4/$KEY}"   # TB_OUT overrides the output dir (e.g. a side dir for the remaining-56 run)
# stale-run guard: a prior run dir that is INCOMPLETE and not owned by a live tb process is stale
# (e.g. a killed partial + leftover tb.lock, OR a lock baked with different args -> the
# "Current run configuration does not match existing lock file" ABORT). tb crashes on a mismatched
# lock BEFORE any task runs, so we must back it up / clear it even when a tb.lock IS present (the old
# guard only cleared when NO lock existed -> crash-loop). Complete dirs are never touched.
# run-id namespaces tb's docker container names (<task>-1-of-1-<run-id>). A concurrent full/OpenRouter
# run sharing run-id "$KEY" would build identically-named containers and collide (404/unknown_agent_error).
# TB_RUNID gives this run a distinct namespace; defaults to $KEY for solo runs.
RUNID="${TB_RUNID:-$KEY}"
RUNDIR="$OUT/$RUNID"
if [ -d "$RUNDIR" ]; then
  DONE_N=$([ -f "$RUNDIR/results.json" ] && python3 -c "import json;d=json.load(open('$RUNDIR/results.json'));print(d.get('n_resolved',0)+d.get('n_unresolved',0))" 2>/dev/null || echo 0)
  if [ "${DONE_N:-0}" -lt "${TERMN:-24}" ] && ! pgrep -f "tb run .*terminalbench_q4/$RUNID" >/dev/null 2>&1; then
    BK="$OUT/_stale_${RUNID}_$(date +%s)"; mv "$RUNDIR" "$BK" 2>/dev/null && echo "[tb-q4] cleared stale/incomplete run dir ($DONE_N tasks, lock-agnostic) -> $BK"
  fi
fi
mkdir -p "$OUT"
# Stratified terminal sample: run the SAME fixed 24-task subset (configs/terminal_sample.txt,
# stratified by difficulty, seed 42) for EVERY model to cut wall-clock ~70%. The remaining 56 tasks
# are saved in configs/terminal_sample_remaining.txt to finish later. Falls back to full-80 (or
# --n-tasks N) only if the sample file is absent.
TARGS=()
if [ "${TB_FULL80:-}" = "1" ]; then
  # FULL-80 mode: no task-id filter => tb runs the ENTIRE terminal-bench-core 0.1.1 set (80 tasks).
  echo "[tb-q4] FULL-80 mode: running the entire terminal-bench-core 0.1.1 set (no task filter)"
elif [ -n "${TB_SAMPLE_FILE:-}" ] && [ -s "$TB_SAMPLE_FILE" ]; then
  # Custom task-id list (e.g. terminal_sample_remaining.txt = the 56 NOT in the 24-sample). Run into a
  # side dir via TB_OUT, then merge with the 24-sample to score the full 80 — reuses the 24 already done.
  while IFS= read -r t; do [ -n "$t" ] && TARGS+=(--task-id "$t"); done < "$TB_SAMPLE_FILE"
  echo "[tb-q4] custom sample file $TB_SAMPLE_FILE: $(( ${#TARGS[@]} / 2 )) tasks"
elif [ -s "$REPO/configs/terminal_sample.txt" ]; then
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
  --run-id "$RUNID" \
  --n-concurrent 3 \
  --global-timeout-multiplier ${TB_MULT:-1.0} \
  --cleanup
  # FIX (2026-08-23): removed `--global-agent-timeout-sec 600`, which OVERRODE every task's native
  # max_agent_timeout_sec (harness.py:639-640) and forced ALL tasks to 600s. 15/24 sample tasks have
  # native timeouts of 900-1800s, so the 600 cap guillotined slow/verbose models mid-task -> spurious
  # agent_timeout (qwen3.8: 67% timeouts vs 21-32% for peers). Now honors each task's native timeout
  # via multiplier 1.0 (terminal-bench default = the recommended condition). The full-precision runner
  # never had this cap, so only Q4 terminal was affected.
