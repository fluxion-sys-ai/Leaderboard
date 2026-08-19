#!/bin/bash
# Q4-local PinchBench ONLY, for all 5 frontier models (GPU / llama.cpp). Order: qwen38 FIRST.
# Pinch is fast + reliable; this deliberately does NOT run Q4 SWE (infeasibly slow) or Terminal.
# Uses the GPU slot; runs in parallel with the non-GPU OpenRouter work (1 GPU + 1 non-GPU). Persistent
# parent so the child llama-server/agent survive. Skip-guarded on the scored json (resumable).
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
log(){ echo "[$(date +'%F %T')] $*" >> "$REPO/logs_q4_pinch_gpu.log"; }
free_gpu(){
  for p in $(pgrep -f 'llama-server'); do kill -9 "$p" 2>/dev/null; done
  for p in $(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  sleep 2
}
declare -A FN=( [qwen38]=qwen3.8-27b-q4f [gemma]=gemma-4-31b-q4f [qwen27]=qwen3.6-27b-q4f [qwen35]=qwen3.5-35b-a3b-q4f [muse]=muse-glimmer-30b-q4f )
log "q4_pinch_gpu up — Q4 Pinch for all 5 (qwen38 first). Pinch ONLY."
for m in qwen38 gemma qwen27 qwen35 muse; do
  fn=${FN[$m]}
  if [ -f "results/scored/$fn/pinchbench.json" ]; then log "Q4 pinch $m already scored — skip"; continue; fi
  free_gpu
  log "Q4 pinch $m FULL (llama.cpp, no_think)"
  bash scripts/pinchbench_q4_run.sh "$m" >>"$REPO/logs_pb_q4_${m}.log" 2>&1 || log "  pinch $m errored"
  # import newest matching transcript (edge-<key>-q4, full 116) -> scored dir
  python3 - "$m" "$fn" <<'PY' 2>/dev/null || log "  import $m failed"
import json, glob, os, sys
key, fn = sys.argv[1], sys.argv[2]
for f in sorted(glob.glob('/home/aliixh/pinchbench-skill/results/*.json'), key=os.path.getmtime, reverse=True):
    try: d = json.load(open(f))
    except Exception: continue
    if f"edge-{key}-q4" in (d.get('model') or ''):
        cs = d.get('category_scores') or {}; tm = sum(c['max_score'] for c in cs.values())
        if tm >= 115:
            os.makedirs(f'results/scored/{fn}', exist_ok=True)
            json.dump({'score':round(sum(c['score'] for c in cs.values())/tm,4),'metric':'pinchbench_pct','benchmark':'pinchbench'},
                      open(f'results/scored/{fn}/pinchbench.json','w')); print('imported'); break
PY
  log "Q4 pinch $m -> $([ -f results/scored/$fn/pinchbench.json ]&&echo scored||echo none)"
done
free_gpu
log "q4_pinch_gpu COMPLETE."
