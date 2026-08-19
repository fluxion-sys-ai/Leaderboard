#!/bin/bash
# Other-4 full-precision PinchBench (muse/qwen27/qwen35/gemma) at REC/DEFAULT. Runs AFTER qwen3.8's
# FULL pipeline (pinch -> terminal -> swe) so qwen3.8 is fully first (user request). Gated on qwen3.8's
# swebench_lite cell (its pipeline's last step). Clears the qwen3.8-only phase flag, then runs the 4
# sequentially (one non-GPU at a time), skip-guarded on the scored cell. Watchdog-managed, resumable.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
log(){ echo "[$(date +'%F %T')] $*" >> "$REPO/logs_other4_pinch.log"; }
declare -A FN=( [muse]=muse-glimmer-30b-full [qwen27]=qwen3.6-27b-full [qwen35]=qwen3.6-35b-a3b-full [gemma]=gemma-4-31b-full )
declare -A MATCH=( [muse]=muse-glimmer-30b [qwen27]=qwen3-6-27b [qwen35]=qwen3-6-35b [gemma]=gemma-4-31b )

# GATE: wait until qwen3.8's full SWE is scored (its pinch->terminal->swe pipeline done), OR the
# qwen3.8 pinch/wrapper have both exited (deadlock-proof).
while [ ! -f results/scored/qwen3.8-27b-full/swebench_lite.json ] \
      && ps -eo args | grep -qE '[b]ash scripts/(rec_pinch_full|qwen38_full_openrouter)\.sh'; do sleep 120; done
rm -f "$REPO/.QWEN38_ONLY_PHASE"   # qwen3.8 fully done -> release the other 4
log "other4_pinch_queue up — qwen3.8 done; running muse/qwen27/qwen35/gemma full pinch (rec/default)."
for k in muse qwen27 qwen35 gemma; do
  fn=${FN[$k]}; match=${MATCH[$k]}
  if [ -f "results/scored/$fn/pinchbench.json" ]; then log "$k already scored — skip"; continue; fi
  log "$k full PinchBench (thinking=high, 116) start"
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
  log "$k -> $([ -f results/scored/$fn/pinchbench.json ]&&echo scored||echo none)"
done
log "other4_pinch_queue COMPLETE."
