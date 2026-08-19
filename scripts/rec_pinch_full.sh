#!/bin/bash
# Re-run FULL-precision PinchBench for all 5 frontier models at REC/DEFAULT params (thinking ON) —
# the prior board cells were the WRONG no_think override (now removed/backed up). OpenRouter, non-GPU,
# ONE model at a time (respects the 1-non-GPU rule). qwen3.8 FIRST (standing priority). Skip-guarded on
# the scored cell (resumable). Persistent parent so child benchmark.py survives the tool-call boundary.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
log(){ echo "[$(date +'%F %T')] $*" >> "$REPO/logs_rec_pinch_full.log"; }
# key -> (scored dir, model-name match substring for the import)
declare -A FN=( [qwen38]=qwen3.8-27b-full [muse]=muse-glimmer-30b-full [qwen27]=qwen3.6-27b-full [qwen35]=qwen3.6-35b-a3b-full [gemma]=gemma-4-31b-full )
declare -A MATCH=( [qwen38]=qwen3-8-27b [muse]=muse-glimmer-30b [qwen27]=qwen3-6-27b [qwen35]=qwen3-6-35b [gemma]=gemma-4-31b )
log "rec_pinch_full up — thinking-ON PinchBench for all 5 full models (qwen3.8 first)."
for k in qwen38 muse qwen27 qwen35 gemma; do
  fn=${FN[$k]}; match=${MATCH[$k]}
  if [ -f "results/scored/$fn/pinchbench.json" ]; then log "$k already scored (rec) — skip"; continue; fi
  log "$k PinchBench (thinking=high, 116 tasks) start"
  bash scripts/pinchbench_full_run.sh "$k" >>"$REPO/logs_pb_rec_${k}.log" 2>&1 || log "  $k pinch non-zero"
  python3 - "$match" "$fn" <<'PY' 2>/dev/null || log "  $k import failed"
import json, glob, os, sys
match, fn = sys.argv[1], sys.argv[2]
for f in sorted(glob.glob('/home/aliixh/pinchbench-skill/results/*.json'), key=os.path.getmtime, reverse=True):
    try: d = json.load(open(f))
    except Exception: continue
    m = (d.get('model') or '').lower().replace('/','-').replace('.','-')
    if match not in m: continue
    cs = d.get('category_scores') or {}; tm = sum(c['max_score'] for c in cs.values())
    if tm >= 115:
        os.makedirs(f'results/scored/{fn}', exist_ok=True)
        json.dump({'score':round(sum(c['score'] for c in cs.values())/tm,4),'metric':'pinchbench_pct','benchmark':'pinchbench'},
                  open(f'results/scored/{fn}/pinchbench.json','w')); print('imported'); break
PY
  log "$k -> $([ -f results/scored/$fn/pinchbench.json ]&&python3 -c "import json;print(round(json.load(open('results/scored/$fn/pinchbench.json'))['score']*100,1),'%')" 2>/dev/null||echo none)"
done
log "rec_pinch_full COMPLETE."
