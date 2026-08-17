#!/bin/bash
# SWE-bench Lite stratified-50, full-precision (OpenRouter), for the 4 full models. Non-GPU.
# Gated on .SWE_PIPELINE_OK (created once the 2-instance smoke verifies end-to-end), so a broken
# pipeline can't burn API $. Sequential (avoids Docker/OpenRouter contention), resumable
# (skips models whose scored json already exists). Detached; watchdog-respawnable.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
log(){ echo "[$(date +'%F %T')] $*"; }
declare -A FULLNAME=( [muse]=muse-glimmer-30b [qwen27]=qwen3.6-27b [qwen35]=qwen3.6-35b-a3b [gemma]=gemma-4-31b )

if [ ! -f .SWE_PIPELINE_OK ]; then log "SWE pipeline not verified yet (.SWE_PIPELINE_OK absent) — exiting; will be relaunched once smoke passes."; exit 0; fi
log "swe_full_queue up — stratified-50 on muse/qwen27/qwen35/gemma (OpenRouter)."
for m in muse qwen27 qwen35 gemma; do
  fn=${FULLNAME[$m]}
  if [ -f "results/scored/${fn}-full/swebench_lite.json" ]; then log "SWE full $m already scored — skip"; continue; fi
  log "SWE full $m --subset strat50 starting"
  bash scripts/swe_agentless_run.sh "$m" --subset strat50 >>"/tmp/swe_full_${m}.log" 2>&1 || log "SWE full $m returned non-zero"
  log "SWE full $m done -> $(python3 -c "import json;d=json.load(open('results/scored/${fn}-full/swebench_lite.json'));print('resolved',d['resolved'],'/',d['n'])" 2>/dev/null || echo '?')"
done
log "swe_full_queue COMPLETE."
