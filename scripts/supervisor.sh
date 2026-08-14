#!/bin/bash
# Self-healing supervisor for the frontier reproduction (full-precision + Q4).
# Loops forever: (re)launches dead tracks, restarts a STALLED GPU track, and stops
# cleanly once every cell is scored. Resumes from per-task cache, so a restart
# never loses work. Runs detached (nohup) — no LLM/tokens needed.
#
#   nohup bash scripts/supervisor.sh >> /tmp/supervisor.log 2>&1 &
set -u
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO" || exit 1
export LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892
export IFBENCH_DIR=/home/aliixh/IFBench
[ -f .hf_token ]       && export HF_TOKEN="$(cat .hf_token)"
[ -f .openrouter_key ] && export OPENROUTER_API_KEY="$(cat .openrouter_key)"

OR_FULL=(muse-glimmer-30b-full gemma-4-31b-full qwen3.6-27b-full qwen3.6-35b-a3b-full)
Q4_MODELS=(gemma-4-31b-q4f qwen3.6-27b-q4f qwen3.5-35b-a3b-q4f)
BENCHES=(ifbench aime2026 pinchbench_clawd)
STALL_SECS=5400            # 90 min. A single Q4 task can reason to the full n_ctx (98304 tok
                           # ≈ 40 min at Q4 speed) on hard prompts — a 40-min guard killed it
                           # mid-task and looped forever at the same index. 90 min lets it finish.

log(){ echo "[$(date +'%F %T')] $*"; }
scored(){ [ -f "results/scored/$1/$2.json" ]; }

or_done(){ for m in "${OR_FULL[@]}"; do for b in "${BENCHES[@]}"; do scored "$m" "$b" || return 1; done; done; }
q4_done(){ for m in "${Q4_MODELS[@]}"; do for b in "${BENCHES[@]}"; do scored "$m" "$b" || return 1; done; done; }
or_running(){ pgrep -f "run_benchmark.py --models-config configs/models_full.yaml" >/dev/null; }
q4_running(){ pgrep -f "models_q4_frontier.yaml" >/dev/null; }

start_or(){
  log "OR: (re)launching full-precision track (resumes from cache)"
  nohup python3 run_benchmark.py --models-config configs/models_full.yaml \
    --benchmarks ifbench aime2026 pinchbench_clawd >> /tmp/track_or_direct.log 2>&1 &
}
start_q4(){
  log "GPU: (re)launching Q4-frontier track (resumes from cache)"
  nohup bash -c '
    cd '"$REPO"'
    export LLAMACPP_BIN='"$LLAMACPP_BIN"' IFBENCH_DIR='"$IFBENCH_DIR"'
    [ -f .hf_token ] && export HF_TOKEN="$(cat .hf_token)"
    for m in '"${Q4_MODELS[*]}"'; do
      echo "[$(date +%T)] GPU: Q4-frontier $m starting"
      python3 run_benchmark.py --models-config configs/models_q4_frontier.yaml \
        --models "$m" --benchmarks ifbench aime2026 pinchbench_clawd
      echo "[$(date +%T)] GPU: Q4-frontier $m DONE"
    done
    echo "[$(date +%T)] GPU: Q4-frontier queue complete"
  ' >> /tmp/track_gpu_q4f.log 2>&1 &
}

# total bytes of Q4 raw output — a monotonically growing progress proxy
q4_bytes(){ find results/raw -path '*-q4f/*.jsonl' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}'; }

log "supervisor up (pid $$)"
prev_bytes=$(q4_bytes); prog_ts=$(date +%s)
while true; do
  # ── Full-precision (OpenRouter) ──
  if or_done; then :; elif ! or_running; then start_or; fi

  # ── Q4-frontier (GPU) with stall guard ──
  if q4_done; then
    :
  elif ! q4_running; then
    start_q4; prev_bytes=$(q4_bytes); prog_ts=$(date +%s)
  else
    cur=$(q4_bytes)
    if [ "$cur" -gt "$prev_bytes" ]; then
      prev_bytes=$cur; prog_ts=$(date +%s)
    elif [ $(( $(date +%s) - prog_ts )) -ge $STALL_SECS ]; then
      log "GPU: STALLED ${STALL_SECS}s with no new output — killing track to restart"
      pkill -f "models_q4_frontier.yaml" 2>/dev/null
      pkill -f "llama-b9892/llama-server" 2>/dev/null
      sleep 5; prog_ts=$(date +%s)
    fi
  fi

  if or_done && q4_done; then log "ALL CELLS SCORED — supervisor exiting"; exit 0; fi
  sleep 180
done
