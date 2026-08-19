#!/bin/bash
# SWE-bench Lite Q4-LOCAL: serve the model's Q4 GGUF on a local llama-server and run the same
# Agentless pipeline against it (SWE_API_BASE override). Muse needs b10433; others b9892.
# Agentless controls per-call temperature (localize 0 / repair 0.8); the server just provides
# thinking (chat-template-kwargs) + a sampling default. Writes results/scored/<FULLNAME>-q4f/.
#
# Usage: swe_agentless_q4_run.sh <gemma|qwen27|qwen35|qwen38|muse> [--subset strat50] [--n N] [--ids ..]
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
PORT=8081
KEY="${1:?usage: swe_agentless_q4_run.sh <gemma|qwen27|qwen35|qwen38|muse> [args...]}"
shift

case "$KEY" in
  gemma)  M=gemma-4-31b-q4f;      TKW='{"enable_thinking":true}';   BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  qwen27) M=qwen3.6-27b-q4f;      TKW='{"enable_thinking":true}';   BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  qwen35) M=qwen3.5-35b-a3b-q4f;  TKW='{"enable_thinking":true}';   BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  qwen38) M=qwen3.8-27b-q4f;      TKW='{"enable_thinking":true}';   BIN=/home/aliixh/llama.cpp/llama-b9892 ;;
  muse)   M=muse-glimmer-30b-q4f; TKW='{"reasoning_effort":"xhigh"}'; BIN=/home/aliixh/llama.cpp/llama.cpp-b10433/build/bin ;;
  *) echo "unknown model key: $KEY"; exit 2 ;;
esac

if pgrep -f "llama-server.*--port $PORT" >/dev/null; then echo "!! GPU busy on $PORT"; exit 1; fi
[ -f "$REPO/.hf_token" ] && export HF_TOKEN="$(cat "$REPO/.hf_token")"
GGUF=$(python3 -c "import sys,yaml;sys.path.insert(0,'.');from src.models_fetch import ensure_gguf;m=next(x for x in yaml.safe_load(open('configs/models_q4_frontier.yaml'))['models'] if x['name']=='$M');print(ensure_gguf(m['name'],m['gguf']))")
echo "[swe-q4] $KEY ($M) gguf=$GGUF bin=$(basename $BIN)"

SLOG=/tmp/swe_q4_${KEY}_server.log
PIDF=/tmp/swe_q4_${KEY}_server.pid
start_server(){
  "$BIN/llama-server" -m "$GGUF" -c 98304 --parallel 2 -ngl 999 \
    --chat-template-kwargs "$TKW" --temp 1.0 --top-p 0.95 \
    --host 127.0.0.1 --port $PORT --no-webui >>"$SLOG" 2>&1 &
  echo $! > "$PIDF"
}
start_server
# keepalive: SWE localize+repair over 51 instances is a LONG run and a heavy repair prompt can spike
# host memory and get the server OOM-killed mid-run. Without this, the remaining instances silently
# fail -> resolved/51 is written as a real-looking but DEFLATED score. Restart after 3 consecutive
# health failures (~45s), with a reload grace so a slow 27B-Q4 reload doesn't cause restart-thrash.
( fails=0; while true; do
    sleep 15
    if timeout 8 curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then fails=0
    else fails=$((fails+1))
      if [ "$fails" -ge 3 ]; then
        echo "[$(date +%T)] [keepalive] server down (3x) -> restarting" >> "$SLOG"
        kill -9 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; start_server
        for _g in $(seq 1 45); do timeout 8 curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 2; done
        fails=0
      fi
    fi
  done ) &
MON=$!
trap 'kill $MON 2>/dev/null; kill -9 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; rm -f "$PIDF"' EXIT
for i in $(seq 1 120); do curl -sf --max-time 8 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 2; done

# point the Agentless pipeline at the local server + tag output as q4f
export SWE_API_BASE="http://127.0.0.1:$PORT/v1"
export SWE_API_KEY="sk-local"
export SWE_PRECISION="q4f"
bash scripts/swe_agentless_run.sh "$KEY" "$@"

# qwen35 dir fix: swe_agentless_run.sh maps key qwen35 -> FULLNAME qwen3.6-35b-a3b (correct for the
# FULL SWE cell), but the Q4 GGUF and the Frontier tab's Qwen3.6-35B-A3B *Q4* SWE cell both use the
# 3.5-35B name (qwen3.5-35b-a3b-q4f). Relocate so the completed Q4 score actually shows on the board
# instead of landing in a dir nothing reads.
if [ "$KEY" = "qwen35" ]; then
  SRC="$REPO/results/scored/qwen3.6-35b-a3b-q4f"; DST="$REPO/results/scored/qwen3.5-35b-a3b-q4f"
  if [ -f "$SRC/swebench_lite.json" ]; then
    mkdir -p "$DST"; mv -f "$SRC/swebench_lite.json" "$DST/swebench_lite.json"
    echo "[swe-q4] relocated qwen35 Q4 SWE score -> $DST/swebench_lite.json"
  fi
fi
