#!/bin/bash
# Q4 GPU agentic queue for the 5 Q4-local frontier models. Order = PINCH -> SWE -> TERMINAL
# (Pinch is fast+reliable, SWE medium, Terminal slow — Terminal LAST so it never blocks the
# others, which is exactly what went wrong before). Solo-GPU, resumable (skips done cells).
# GATED: waits for the Qwen3.8 priority run (.QWEN38_DONE) and honors .PAUSE_MAIN_QUEUES.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
export PATH="$HOME/.local/bin:$PATH"
log(){ echo "[$(date +'%F %T')] $*"; }
free_gpu(){ for p in $(pgrep -f 'llama-server'); do kill -9 "$p" 2>/dev/null; done; }
MODELS=(gemma qwen27 qwen35 qwen38 muse)
declare -A FN=( [gemma]=gemma-4-31b-q4f [qwen27]=qwen3.6-27b-q4f [qwen35]=qwen3.5-35b-a3b-q4f [qwen38]=qwen3.8-27b-q4f [muse]=muse-glimmer-30b-q4f )

# gate: don't start until Qwen3.8 priority is done, and not while paused
until [ -f .QWEN38_DONE ] && [ ! -f .PAUSE_MAIN_QUEUES ]; do sleep 120; done
log "q4_agentic_queue up (Pinch -> SWE -> Terminal). GPU free wait..."
until ! pgrep -f 'run_benchmark.py|models_q4_frontier' >/dev/null; do sleep 60; done

# ---- Phase 1: PinchBench Q4 (all 5, incl Glimmer) — edgelocal, no_think, smoke-gated ----
for m in "${MODELS[@]}"; do
  [ -f "results/scored/${FN[$m]}/pinchbench.json" ] && { log "Pinch Q4 $m done — skip"; continue; }
  free_gpu; sleep 3
  log "PINCH Q4 $m SMOKE (2)"
  bash scripts/pinchbench_q4_run.sh "$m" 2 >"/tmp/pb_q4_${m}_smoke.log" 2>&1 || true
  NZ=$(grep -E 'Task task.*: [0-9.]+/1.0' "/tmp/pb_q4_${m}_smoke.log" 2>/dev/null | grep -cvE ': 0.0/' || echo 0)
  log "  smoke: ${NZ} non-zero"
  [ "${NZ:-0}" -lt 1 ] && { log "  Pinch Q4 $m smoke all-zero — SKIP full (needs a look)"; continue; }
  free_gpu; sleep 3
  log "  PINCH Q4 $m FULL"
  bash scripts/pinchbench_q4_run.sh "$m" >>"/tmp/pb_q4_${m}_full.log" 2>&1 || log "  pinch errored"
  python3 - "$m" "${FN[$m]}" <<'PY' 2>/dev/null || true
import json,glob,os,sys
key,fn=sys.argv[1],sys.argv[2]
for f in sorted(glob.glob('/home/aliixh/pinchbench-skill/results/*.json'),key=os.path.getmtime,reverse=True):
    d=json.load(open(f))
    if f"edge-{key}-q4" in (d.get('model') or ''):
        cs=d.get('category_scores') or {};tm=sum(c['max_score'] for c in cs.values())
        if tm>=115:
            os.makedirs(f'results/scored/{fn}',exist_ok=True)
            json.dump({'score':round(sum(c['score'] for c in cs.values())/tm,4),'metric':'pinchbench_pct','benchmark':'pinchbench'},open(f'results/scored/{fn}/pinchbench.json','w'));print('imported');break
PY
done
log "PinchBench Q4 phase complete."

# ---- Phase 2: SWE-bench Lite Q4 (all 5) ----
for m in "${MODELS[@]}"; do
  [ -f "results/scored/${FN[$m]}/swebench_lite.json" ] && { log "SWE Q4 $m done — skip"; continue; }
  free_gpu; sleep 3
  log "SWE Q4 $m (strat50)"
  bash scripts/swe_agentless_q4_run.sh "$m" --subset strat50 >>"$REPO/logs_swe_q4_${m}.log" 2>&1 || log "  SWE Q4 $m errored (see logs_swe_q4_${m}.log)"
done
log "SWE-bench Q4 phase complete."

# ---- Phase 3: TerminalBench Q4 (all 5) — LAST (slow), so it can't block Pinch/SWE ----
for m in "${MODELS[@]}"; do
  TBF="results/terminalbench_q4/$m/$m/results.json"
  [ -f "$TBF" ] && [ "$(python3 -c "import json;d=json.load(open('$TBF'));print(d['n_resolved']+d['n_unresolved'])" 2>/dev/null||echo 0)" -ge 80 ] && { log "Terminal Q4 $m done — skip"; continue; }
  free_gpu; sleep 3
  log "TERMINAL Q4 $m FULL"
  bash scripts/terminalbench_q4_run.sh "$m" >>"$REPO/logs_tb_q4_${m}.log" 2>&1 || log "  terminal errored"
done
log "TerminalBench Q4 phase complete."

free_gpu
log "q4_agentic_queue COMPLETE."
