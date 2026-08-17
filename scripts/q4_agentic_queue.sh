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
  declare -A SWEFN=( [gemma]=gemma-4-31b-q4f [qwen27]=qwen3.6-27b-q4f [qwen35]=qwen3.5-35b-a3b-q4f [qwen38]=qwen3.8-27b-q4f [muse]=muse-glimmer-30b-q4f )
  for m in "${MODELS[@]}"; do
    if [ -f "results/scored/${SWEFN[$m]}/swebench_lite.json" ]; then log "SWE Q4 $m already done — skip"; continue; fi
    free_gpu; sleep 3
    log "SWE Q4 $m FULL starting"
    bash scripts/swe_agentless_q4_run.sh "$m" --subset strat50 >>"/tmp/swe_q4_${m}.log" 2>&1 || log "SWE Q4 $m errored"
    log "SWE Q4 $m done"
  done
  log "SWE-bench Q4 phase complete."
else
  log "SWE Q4 runner (scripts/swe_agentless_q4_run.sh) not present yet — SWE Q4 phase SKIPPED. Build it, then re-run this queue."
fi

# ---- Phase 3: PinchBench Q4 (all 5, incl. Glimmer) — edgelocal provider, no_think, smoke-gated ----
if [ -x scripts/pinchbench_q4_run.sh ]; then
  declare -A PBFN=( [gemma]=gemma-4-31b-q4f [qwen27]=qwen3.6-27b-q4f [qwen35]=qwen3.5-35b-a3b-q4f [qwen38]=qwen3.8-27b-q4f [muse]=muse-glimmer-30b-q4f )
  for m in "${MODELS[@]}"; do
    if [ -f "results/scored/${PBFN[$m]}/pinchbench.json" ]; then log "Pinch Q4 $m already done — skip"; continue; fi
    free_gpu; sleep 3
    # SMOKE 2 tasks first (thinking-ON/misconfig would zero it) — only run full if >=1 non-zero
    log "Pinch Q4 $m SMOKE (2 tasks)"
    bash scripts/pinchbench_q4_run.sh "$m" 2 >"/tmp/pb_q4_${m}_smoke.log" 2>&1 || true
    PASS=$(grep -cE 'Task task.*: [0-9.]+/1.0' "/tmp/pb_q4_${m}_smoke.log" 2>/dev/null | head -1)
    NZ=$(grep -E 'Task task.*: [0-9.]+/1.0' "/tmp/pb_q4_${m}_smoke.log" 2>/dev/null | grep -cvE ': 0.0/' || echo 0)
    log "Pinch Q4 $m smoke: ${NZ} non-zero of ${PASS}"
    if [ "${NZ:-0}" -lt 1 ]; then log "Pinch Q4 $m SMOKE all-zero — SKIPPING full (needs a human look), not wasting GPU."; continue; fi
    free_gpu; sleep 3
    log "Pinch Q4 $m FULL (116 tasks) starting"
    bash scripts/pinchbench_q4_run.sh "$m" >>"/tmp/pb_q4_${m}_full.log" 2>&1 || log "Pinch Q4 $m errored"
    # import newest pinch result -> results/scored/<q4name>/pinchbench.json (weighted category_scores)
    python3 - "$m" "${PBFN[$m]}" <<'PY' 2>/dev/null || true
import json,glob,os,sys
key,fn=sys.argv[1],sys.argv[2]
fs=sorted(glob.glob('/home/aliixh/pinchbench-skill/results/*.json'),key=os.path.getmtime)
for f in reversed(fs):
    d=json.load(open(f))
    if f"edge-{key}-q4" in (d.get('model') or ''):
        cs=d.get('category_scores') or {}; tm=sum(c['max_score'] for c in cs.values())
        if tm>=115:
            os.makedirs(f'results/scored/{fn}',exist_ok=True)
            json.dump({'score':round(sum(c['score'] for c in cs.values())/tm,4),'metric':'pinchbench_pct','benchmark':'pinchbench'},open(f'results/scored/{fn}/pinchbench.json','w'))
            print('imported',fn); break
PY
    log "Pinch Q4 $m done"
  done
  log "PinchBench Q4 phase complete."
else
  log "Pinch Q4 runner not present — Phase 3 SKIPPED."
fi

free_gpu
log "q4_agentic_queue COMPLETE."
