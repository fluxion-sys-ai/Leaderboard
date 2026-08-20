#!/bin/bash
# Keep the box saturated: run the full Muse-tab reproduction across both precisions.
#  - GPU track: Q4-local IFBench, sequential on the single A100 (Muse excluded — arch
#    unsupported by llama.cpp yet).
#  - OpenRouter track: full-precision IFBench + AIME + tau3-banking, in parallel (no GPU).
# Idempotent-ish: run_benchmark caches per-task, so re-runs resume.
set -u
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
export HF_TOKEN="$(cat .hf_token)"
export OPENROUTER_API_KEY="$(cat .openrouter_key)"
export IFBENCH_DIR=/home/aliixh/IFBench
export LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892

log(){ echo "[$(date +%H:%M:%S)] $*"; }

# ── Track 1: OpenRouter full-precision — IFBench + AIME across all 4 frontier models ──
( log "OR: full-precision ifbench+aime2026 (4 models) starting"
  python3 run_benchmark.py --models-config configs/models_full.yaml \
    --benchmarks ifbench aime2026
  log "OR: full-precision ifbench+aime2026 DONE"
) >> /tmp/track_or_direct.log 2>&1 &

# ── Track 2: OpenRouter full-precision — tau3-banking (general agentic), all 4 ──
( for m in muse qwen27 qwen35 gemma; do
    log "OR: tau3-banking $m starting"
    bash scripts/tau3_banking_run.sh "$m" 20 1 || log "tau3 $m failed"
    log "OR: tau3-banking $m done"
  done
) >> /tmp/track_or_tau3.log 2>&1 &

# ── Track 3: GPU Q4-local frontier — recommended params + thinking ON, sequential (one A100) ──
# Uses models_q4_frontier.yaml (own `*-q4f` names → does NOT touch the greedy board's cells).
( for m in gemma-4-31b-q4f qwen3.6-27b-q4f qwen3.5-35b-a3b-q4f; do
    log "GPU: Q4-frontier ifbench+aime2026 $m starting"
    python3 run_benchmark.py --models-config configs/models_q4_frontier.yaml \
      --models "$m" --benchmarks ifbench aime2026
    log "GPU: Q4-frontier $m DONE"
  done
  log "GPU: Q4-frontier queue complete"
) >> /tmp/track_gpu_q4.log 2>&1 &

log "all 3 tracks launched (pids: $(jobs -p | tr '\n' ' '))"
wait
log "ALL TRACKS COMPLETE"
