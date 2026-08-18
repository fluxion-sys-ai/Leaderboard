#!/bin/bash
# Qwen3.8-27B Q4 PRIORITY sequence. Order = PINCH -> SWE -> TERMINAL (Terminal LAST because it's
# the ~9h bottleneck; Pinch+SWE are ~3-4h each, so their numbers land first). Solo-GPU, resumable.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
log(){ echo "[$(date +'%F %T')] $*"; }
free_gpu(){ for p in $(pgrep -f 'llama-server'); do kill -9 "$p" 2>/dev/null; done; }
FN=qwen3.8-27b-q4f

log "===== Qwen3.8 Q4 PRIORITY: Pinch -> SWE -> Terminal ====="

# ---- 1/3 PinchBench Q4 (full 116, no_think server-enforced) ----
if [ -f "results/scored/$FN/pinchbench.json" ]; then log "Pinch Q4 qwen38 done — skip"; else
  free_gpu; sleep 3
  log "1/3 Pinch Q4 qwen38 FULL (116)"
  bash scripts/pinchbench_q4_run.sh qwen38 >>"$REPO/logs_pb_q4_qwen38.log" 2>&1 || log "  pinch errored"
  python3 - <<'PY' 2>/dev/null || true
import json,glob,os
for f in sorted(glob.glob('/home/aliixh/pinchbench-skill/results/*.json'),key=os.path.getmtime,reverse=True):
    d=json.load(open(f))
    if 'edge-qwen38-q4' in (d.get('model') or ''):
        cs=d.get('category_scores') or {}; tm=sum(c['max_score'] for c in cs.values())
        if tm>=115:
            os.makedirs('results/scored/qwen3.8-27b-q4f',exist_ok=True)
            json.dump({'score':round(sum(c['score'] for c in cs.values())/tm,4),'metric':'pinchbench_pct','benchmark':'pinchbench'},open('results/scored/qwen3.8-27b-q4f/pinchbench.json','w')); print('imported'); break
PY
  log "  Pinch Q4 qwen38 -> $(python3 -c "import json;print(round(json.load(open('results/scored/$FN/pinchbench.json'))['score']*100,1))" 2>/dev/null || echo '?')"
fi

# ---- 2/3 SWE-Lite Q4 ----
if [ -f "results/scored/$FN/swebench_lite.json" ]; then log "SWE Q4 qwen38 done — skip"; else
  free_gpu; sleep 3
  log "2/3 SWE Q4 qwen38 (strat50)"
  bash scripts/swe_agentless_q4_run.sh qwen38 --subset strat50 >>"$REPO/logs_swe_q4_qwen38.log" 2>&1 || log "  swe errored"
fi

# ---- 3/3 Terminal Q4 (LAST — the slow one) ----
TBF="results/terminalbench_q4/qwen38/qwen38/results.json"
if [ -f "$TBF" ] && [ "$(python3 -c "import json;d=json.load(open('$TBF'));print(d['n_resolved']+d['n_unresolved'])" 2>/dev/null||echo 0)" -ge 80 ]; then
  log "Terminal Q4 qwen38 done — skip"; else
  free_gpu; sleep 3
  log "3/3 Terminal Q4 qwen38 FULL"
  bash scripts/terminalbench_q4_run.sh qwen38 >>"$REPO/logs_tb_q4_qwen38.log" 2>&1 || log "  terminal errored"
fi

free_gpu
log "===== Qwen3.8 Q4 sequence COMPLETE ====="