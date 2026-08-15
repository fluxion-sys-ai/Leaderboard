#!/bin/bash
# WEEKEND unattended automation. Loops forever:
#   1. imports any newly-finished full-precision PinchBench → results/scored/<model>-full/pinchbench.json
#   2. rebuilds the board + pushes to GitHub (so the live leaderboard stays current)
#   3. CREDIT GUARD: if OpenRouter credits drop below $20, kills the PAID (OpenRouter) runs so
#      they don't hard-fail/spin — the GPU/Q4 work (free) keeps going. Writes a STOP flag.
# Detached, low-cost (a rebuild + a git push every 20 min). Safe to run alongside the supervisor.
set -u
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO" || exit 1
KEYFILE="$REPO/.openrouter_key"
STOP_FLAG="$REPO/.PAID_STOPPED"
log(){ echo "[$(date +'%F %T')] $*"; }

import_pinch(){
python3 - <<'PY' 2>/dev/null
import json,glob,os
def tf(m):
    m=m.lower().replace('/','-').replace('.','-')
    return {'muse-glimmer-30b':'muse-glimmer-30b-full','qwen3-6-27b':'qwen3.6-27b-full','qwen3-6-35b':'qwen3.6-35b-a3b-full','gemma-4-31b':'gemma-4-31b-full'}.get(next((k for k in ['muse-glimmer-30b','qwen3-6-27b','qwen3-6-35b','gemma-4-31b'] if k in m),''))
for f in glob.glob('/home/aliixh/pinchbench-skill/results/*.json'):
    try:d=json.load(open(f))
    except:continue
    cs=d.get('category_scores') or {};tm=sum(c['max_score'] for c in cs.values())
    if tm<115:continue
    mdl=tf(d.get('model',''))
    if mdl:
        os.makedirs(f'results/scored/{mdl}',exist_ok=True)
        json.dump({'score':round(sum(c['score'] for c in cs.values())/tm,4),'metric':'pinchbench_pct','benchmark':'pinchbench'},open(f'results/scored/{mdl}/pinchbench.json','w'))
PY
}

credits(){
  curl -s -H "Authorization: Bearer $(cat "$KEYFILE")" https://openrouter.ai/api/v1/credits 2>/dev/null \
   | python3 -c 'import json,sys;d=json.load(sys.stdin)["data"];print(round(d["total_credits"]-d["total_usage"],2))' 2>/dev/null
}

log "weekend_auto up (pid $$)"
while true; do
  import_pinch
  python3 -m src.report.build_leaderboard >/dev/null 2>&1 && cp leaderboard.html docs/index.html
  if ! git diff --quiet docs/index.html 2>/dev/null; then
    git add docs/index.html leaderboard.html results/scored/*/pinchbench.json 2>/dev/null
    git -c user.name="aliixh" -c user.email="aliixhuang@gmail.com" commit -q -m "leaderboard: auto-refresh (weekend)" 2>/dev/null
    git push origin main -q 2>/dev/null && log "board pushed"
  fi
  C=$(credits)
  if [ -n "$C" ] && python3 -c "import sys;sys.exit(0 if float('$C')<20 else 1)" 2>/dev/null; then
    if [ ! -f "$STOP_FLAG" ]; then
      log "CREDIT GUARD: \$$C < \$20 — killing PAID (OpenRouter) runs; GPU/Q4 continues."
      touch "$STOP_FLAG"
      for pid in $(ps -eo pid,args | grep -E "pinchbench_full_run|benchmark.py|run_benchmark.py --models-config configs/models_full" | grep -v grep | awk '{print $1}'); do kill -9 $pid 2>/dev/null; done
    fi
  fi
  sleep 1200   # 20 min
done
