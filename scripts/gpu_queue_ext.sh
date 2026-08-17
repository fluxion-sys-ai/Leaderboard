#!/bin/bash
# GPU queue EXTENSION — runs AFTER the 3-model Q4 grid + Q4 PinchBench finish and the GPU frees.
# Adds the two remaining Q4 models to the grid, each SMOKE-GATED first (user rule: smoke before full):
#   1. Muse Glimmer 30B Q4  — needs llama.cpp b10433 (b9892 lacks the arch). smoke aime --limit 2.
#   2. Qwen3.8-27B Q4        — standard b9892. smoke aime --limit 2.
# If a model's smoke produces no scored cell (model FAILED to load/emit), it is SKIPPED + logged,
# not run full — so a broken model can't burn the weekend. Detached, solo-GPU.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
export IFBENCH_DIR=/home/aliixh/IFBench   # NOTE: case-sensitive; lowercase path breaks the IFBench verifier import -> silent 0.0
[ -f .hf_token ] && export HF_TOKEN="$(cat .hf_token)"
LOG=/tmp/gpu_queue_ext.log
log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOG"; }

gpu_free(){ ! pgrep -f "llama-server" >/dev/null && ! pgrep -f "models_q4_frontier" >/dev/null; }

log "gpu_queue_ext up — waiting for qwen35-Q4 + Q4-pinch to finish and GPU to free..."
until [ -f results/scored/qwen3.5-35b-a3b-q4f/aime2026.json ] && gpu_free && ! pgrep -f "pinchbench_rec" >/dev/null; do
  sleep 180
done
log "GPU free + prior Q4 work done. Starting Muse Q4 + Qwen3.8 Q4 (smoke-gated)."

run_model(){  # $1=model name  $2=llamacpp bin
  local M="$1" BIN="$2"
  if [ -f "results/scored/$M/aime2026.json" ] && [ -f "results/scored/$M/ifbench.json" ]; then log "$M already complete — skip"; return; fi
  log "$M: SMOKE (aime --limit 2) on $(basename "$BIN")"
  LLAMACPP_BIN="$BIN" python3 run_benchmark.py --models-config configs/models_q4_frontier.yaml \
    --models "$M" --benchmarks aime2026 --limit 2 >>"$LOG" 2>&1 || true
  if [ ! -f "results/raw/$M/aime2026.jsonl" ] && [ ! -f "results/scored/$M/aime2026.json" ]; then
    log "$M: SMOKE FAILED (no output — model did not load/emit). SKIPPING full run. Needs a human look."; return
  fi
  local NONEMPTY=$(python3 -c "import json,glob;print(sum(1 for l in open(glob.glob('results/raw/$M/aime2026.jsonl')[0]) if len((json.loads(l).get('output') or '').strip())>50))" 2>/dev/null || echo 0)
  log "$M: smoke produced $NONEMPTY/2 non-empty outputs"
  if [ "${NONEMPTY:-0}" -lt 1 ]; then log "$M: smoke outputs all empty — SKIPPING full run, needs a human look."; return; fi
  log "$M: smoke OK — running FULL ifbench + aime2026"
  # clear the 2-task smoke so the full aime run isn't capped by cached partial
  rm -f "results/raw/$M/aime2026.jsonl" "results/scored/$M/aime2026.json" 2>/dev/null
  LLAMACPP_BIN="$BIN" python3 run_benchmark.py --models-config configs/models_q4_frontier.yaml \
    --models "$M" --benchmarks ifbench aime2026 >>"$LOG" 2>&1 || log "$M: full run errored"
  log "$M: FULL run done — $(ls results/scored/$M/ 2>/dev/null | tr '\n' ' ')"
}

run_model muse-glimmer-30b-q4f /home/aliixh/llama.cpp/llama.cpp-b10433/build/bin
gpu_free || sleep 60
run_model qwen3.8-27b-q4f      /home/aliixh/llama.cpp/llama-b9892
log "gpu_queue_ext COMPLETE — Muse Q4 + Qwen3.8 Q4 finished (or skipped w/ reason above)."
