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
log "qwen38_full_openrouter up — Pinch/IF-AIME/SWE/Terminal via OpenRouter fp8."

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

# 2) IFBench + AIME (thinking ON, fp8)
if [ ! -f "results/scored/$FN/ifbench.json" ] || [ ! -f "results/scored/$FN/aime2026.json" ]; then
  log "IF/AIME start"
  python3 run_benchmark.py --models-config configs/models_qwen38_full_ifaime.yaml \
    --models qwen3.8-27b-full --benchmarks aime2026 ifbench >>"$REPO/logs_ifaime_qwen38_full.log" 2>&1 || log "IF/AIME non-zero"
  log "IF/AIME done -> ifbench=$([ -f results/scored/$FN/ifbench.json ]&&echo y||echo n) aime=$([ -f results/scored/$FN/aime2026.json ]&&echo y||echo n)"
fi

# 3) SWE-Lite on the 20-sample (OpenRouter fp8 — no SWE_API_BASE => OpenRouter)
if [ ! -f "results/scored/$FN/swebench_lite.json" ]; then
  log "SWE start (20-sample)"
  bash scripts/swe_agentless_run.sh qwen38 --subset strat50 >>"$REPO/logs_swe_full_qwen38.log" 2>&1 || log "SWE non-zero"
  log "SWE done -> $([ -f results/scored/$FN/swebench_lite.json ]&&echo scored||echo none)"
fi

# 4) TerminalBench (full 80, terminus-2 via OpenRouter)
if [ ! -f "results/terminalbench/qwen38/qwen38/results.json" ]; then
  export PATH="$HOME/.local/bin:$PATH"
  log "Terminal start (full 80)"
  bash scripts/terminalbench_run.sh qwen38 >>"$REPO/logs_tb_full_qwen38.log" 2>&1 || log "terminal non-zero"
  log "Terminal done"
fi
log "qwen38_full_openrouter COMPLETE."
