#!/bin/bash
# Qwen3.8-27B FULL-precision — ALL cells via OpenRouter (qwen/qwen3.8-27b, fp8). NO self-hosted vLLM.
# Order: Pinch (fast) -> IFBench+AIME -> SWE-Lite (20-sample) -> Terminal (full 80). Every step is
# skip-guarded on its scored output, so this is fully resumable (IF/AIME also caches per-task).
# Persistent parent so child run_benchmark/agentless/tb procs survive the tool-call boundary.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
export IFBENCH_DIR=/home/aliixh/IFBench
FN=qwen3.8-27b-full
log(){ echo "[$(date +'%F %T')] $*" >> "$REPO/logs_qwen38_full_or.log"; }
log "qwen38_full_openrouter up — Pinch/Terminal/SWE via OpenRouter fp8."
# DEPRIORITIZED (user): the non-GPU slot runs the other-4 full SWE first; qwen3.8-full waits until
# muse/qwen27/qwen35/gemma SWE are all scored — OR swe_full_queue has exited — then runs.
while ! { [ -f results/scored/muse-glimmer-30b-full/swebench_lite.json ] && [ -f results/scored/qwen3.6-27b-full/swebench_lite.json ] \
       && [ -f results/scored/qwen3.6-35b-a3b-full/swebench_lite.json ] && [ -f results/scored/gemma-4-31b-full/swebench_lite.json ]; } \
      && pgrep -f 'swe_full_queue' >/dev/null; do sleep 120; done
log "other-4 full SWE done (or queue exited) — starting qwen3.8-full."

# 1) PinchBench (no_think — thinking-ON zeroes agentic) + import to the scored dir
if [ ! -f "results/scored/$FN/pinchbench.json" ]; then
  log "Pinch start"
  bash scripts/pinchbench_full_run.sh qwen38 >>"$REPO/logs_pb_full_qwen38.log" 2>&1 || log "pinch non-zero"
  python3 - <<'PY' 2>/dev/null || log "pinch import failed"
import json, glob, os
best=None
for f in sorted(glob.glob('/home/aliixh/pinchbench-skill/results/*.json'), key=os.path.getmtime, reverse=True):
    try: d=json.load(open(f))
    except Exception: continue
    m=(d.get('model') or '').lower().replace('/','-').replace('.','-')
    if 'qwen3-8-27b' not in m: continue          # ONLY Qwen3.8-27B (won't match 3.6-27b)
    cs=d.get('category_scores') or {}; tm=sum(c['max_score'] for c in cs.values())
    if tm>=115:
        os.makedirs('results/scored/qwen3.8-27b-full', exist_ok=True)
        json.dump({'score':round(sum(c['score'] for c in cs.values())/tm,4),'metric':'pinchbench_pct','benchmark':'pinchbench'},
                  open('results/scored/qwen3.8-27b-full/pinchbench.json','w')); print('imported'); break
PY
  log "Pinch done -> $([ -f results/scored/$FN/pinchbench.json ]&&echo scored||echo none)"
fi

# (IFBench + AIME intentionally SKIPPED for qwen3.8-full per user — only Pinch, SWE, Terminal.)

# 2) TerminalBench (full 80, terminus-2 via OpenRouter) — order per user: Pinch -> Terminal -> SWE
if [ ! -f "results/terminalbench/qwen38/qwen38/results.json" ]; then
  export PATH="$HOME/.local/bin:$PATH"
  log "Terminal start (full 80)"
  bash scripts/terminalbench_run.sh qwen38 >>"$REPO/logs_tb_full_qwen38.log" 2>&1 || log "terminal non-zero"
  log "Terminal done"
fi

# 3) SWE-Lite on the 20-sample (OpenRouter fp8 — no SWE_API_BASE => OpenRouter)
if [ ! -f "results/scored/$FN/swebench_lite.json" ]; then
  log "SWE start (20-sample)"
  bash scripts/swe_agentless_run.sh qwen38 --subset strat50 >>"$REPO/logs_swe_full_qwen38.log" 2>&1 || log "SWE non-zero"
  log "SWE done -> $([ -f results/scored/$FN/swebench_lite.json ]&&echo scored||echo none)"
fi
log "qwen38_full_openrouter COMPLETE."
