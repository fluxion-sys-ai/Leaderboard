#!/bin/bash
# Q4 GPU agentic queue: runs TerminalBench (now) and SWE-bench Lite (when its runner exists)
# for all five Q4-local frontier models, sequentially (solo GPU). Each model serves its own
# GGUF via terminalbench_q4_run.sh / swe_agentless_q4_run.sh. Kills any stray llama-server
# between models so the solo-GPU guard never trips. Detached, resumable (skips done cells).
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
export PATH="$HOME/.local/bin:$PATH"
log(){ echo "[$(date +'%F %T')] $*"; }
MODELS=(gemma qwen27 qwen35 qwen38 muse)

free_gpu(){ for p in $(pgrep -f 'llama-server'); do kill -9 "$p" 2>/dev/null; done; }

log "q4_agentic_queue up. GPU free wait..."
until ! pgrep -f 'run_benchmark.py|models_q4_frontier' >/dev/null; do sleep 60; done

# ---- Phase 1: TerminalBench Q4 (all 5) ----
for m in "${MODELS[@]}"; do
  if [ -f "results/terminalbench_q4/$m/$m/results.json" ]; then log "TB Q4 $m already done — skip"; continue; fi
  free_gpu; sleep 3
  log "TB Q4 $m FULL starting"
  bash scripts/terminalbench_q4_run.sh "$m" >>"/tmp/tb_q4_${m}.log" 2>&1 || log "TB Q4 $m errored"
  log "TB Q4 $m done -> $(python3 -c "import json;print(json.load(open('results/terminalbench_q4/$m/$m/results.json'))['accuracy'])" 2>/dev/null || echo '?')"
done
log "TerminalBench Q4 phase complete."

# ---- Phase 2: SWE-bench Lite Q4 (all 5) — only if the Q4 SWE runner exists ----
if [ -x scripts/swe_agentless_q4_run.sh ]; then
  for m in "${MODELS[@]}"; do
    if [ -f "results/scored/${m}-q4f-swe/swebench_lite.json" ]; then log "SWE Q4 $m already done — skip"; continue; fi
    free_gpu; sleep 3
    log "SWE Q4 $m FULL starting"
    bash scripts/swe_agentless_q4_run.sh "$m" --subset strat50 >>"/tmp/swe_q4_${m}.log" 2>&1 || log "SWE Q4 $m errored"
    log "SWE Q4 $m done"
  done
  log "SWE-bench Q4 phase complete."
else
  log "SWE Q4 runner (scripts/swe_agentless_q4_run.sh) not present yet — SWE Q4 phase SKIPPED. Build it, then re-run this queue."
fi
free_gpu
log "q4_agentic_queue COMPLETE."
