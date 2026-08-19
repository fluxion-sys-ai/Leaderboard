#!/bin/bash
# Qwen3.8-27B FULL-precision via OpenRouter (qwen/qwen3.8-27b, fp8) — NO self-hosted vLLM.
# Runs IFBench+AIME, then SWE-Lite (20-sample), then imports. Persistent parent so its child
# run_benchmark/agentless procs survive (a bare backgrounded run gets reaped at tool-call end).
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
export IFBENCH_DIR=/home/aliixh/IFBench
log(){ echo "[$(date +'%F %T')] $*" >> "$REPO/logs_qwen38_full_or.log"; }

log "qwen38_full_openrouter up — IF/AIME then SWE via OpenRouter fp8."

# 1) IFBench + AIME (OpenRouter fp8, thinking ON)
if [ ! -f results/scored/qwen3.8-27b-full/ifbench.json ] || [ ! -f results/scored/qwen3.8-27b-full/aime2026.json ]; then
  log "IF/AIME start"
  python3 run_benchmark.py --models-config configs/models_qwen38_full_ifaime.yaml \
    --models qwen3.8-27b-full --benchmarks aime2026 ifbench >>"$REPO/logs_ifaime_qwen38_full.log" 2>&1 || log "IF/AIME non-zero"
  log "IF/AIME done -> ifbench=$([ -f results/scored/qwen3.8-27b-full/ifbench.json ]&&echo y||echo n) aime=$([ -f results/scored/qwen3.8-27b-full/aime2026.json ]&&echo y||echo n)"
fi

# 2) SWE-Lite on the 20-sample (OpenRouter fp8 — no SWE_API_BASE => OpenRouter). qwen38 EXTRA gets an
#    fp8 provider pin injected here via env so we don't have to edit the (running) swe_agentless_run.sh.
if [ ! -f results/scored/qwen3.8-27b-full/swebench_lite.json ]; then
  log "SWE start (20-sample, OpenRouter fp8)"
  bash scripts/swe_agentless_run.sh qwen38 --subset strat50 >>"$REPO/logs_swe_full_qwen38.log" 2>&1 || log "SWE non-zero"
  log "SWE done -> $([ -f results/scored/qwen3.8-27b-full/swebench_lite.json ]&&echo scored||echo none)"
fi
log "qwen38_full_openrouter COMPLETE."
