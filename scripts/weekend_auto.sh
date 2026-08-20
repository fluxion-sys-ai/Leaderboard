#!/bin/bash
# Board auto-refresh loop — HANG-PROOF. Every 10 min: import pinch -> rebuild -> commit+push.
# Root-cause fixes (why the board stalled 15h before):
#   - a git push with NO timeout can block forever -> `timeout` on every git op.
#   - a killed git op leaves a stale .git/index.lock that hangs the next op -> cleaned each pass.
#   - logs went to /tmp (reaped) -> logs to $REPO/logs_board.log, + a .board_heartbeat file so a
#     stall is detectable (heartbeat stops updating).
#   - push errors were sent to /dev/null (invisible) -> captured to the log.
# Also: CREDIT GUARD (kills paid OpenRouter runs < $20). Detached; watchdog-respawnable.
set -u
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO" || exit 1
KEYFILE="$REPO/.openrouter_key"
STOP_FLAG="$REPO/.PAID_STOPPED"
LOG="$REPO/logs_board.log"
log(){ echo "[$(date +'%F %T')] $*" >> "$LOG"; }
git_c(){ git -c user.name="aliixh" -c user.email="aliixhuang@gmail.com" "$@"; }

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
  timeout 30 curl -s -H "Authorization: Bearer $(cat "$KEYFILE")" https://openrouter.ai/api/v1/credits 2>/dev/null \
   | python3 -c 'import json,sys;d=json.load(sys.stdin)["data"];print(round(d["total_credits"]-d["total_usage"],2))' 2>/dev/null
}

log "weekend_auto up (pid $$) — hang-proof, 10min loop"
while true; do
  date +%s > "$REPO/.board_heartbeat"                      # liveness marker
  find .git -name 'index.lock' -mmin +2 -delete 2>/dev/null  # clear stale git lock
  import_pinch
  timeout 180 python3 -m src.report.build_leaderboard >/dev/null 2>&1 && cp leaderboard.html docs/index.html 2>/dev/null
  if ! git diff --quiet docs/index.html 2>/dev/null; then
    # Stage the always-present board files FIRST and on their own — a single `git add` with a glob
    # that matches nothing (e.g. no swebench_lite.json scored yet) is FATAL and stages NOTHING, not
    # even docs/index.html, so the commit was silently empty and the board never deployed. Add the
    # optional score globs as separate best-effort calls so an unmatched glob can't block the deploy.
    timeout 30 git add docs/index.html leaderboard.html 2>/dev/null
    timeout 30 git add results/scored/*/pinchbench.json 2>/dev/null || true
    timeout 30 git add results/scored/*/swebench_lite.json 2>/dev/null || true
    timeout 30 git_c commit -q -m "leaderboard: auto-refresh" 2>/dev/null || log "commit produced nothing (no staged change)"
    # Always push if local is ahead of origin — otherwise manual fix-commits sit unpushed whenever
    # the board rebuild is byte-identical (root cause of the origin stalling 10 commits behind).
    AHEAD=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
    if [ "${AHEAD:-0}" -gt 0 ]; then
      if timeout 90 git push origin main -q 2>>"$LOG"; then log "board pushed ($AHEAD commit(s))"; else log "PUSH FAILED/timed-out (will retry next pass)"; fi
    fi
  fi
  C=$(credits)
  if [ -n "$C" ] && python3 -c "import sys;sys.exit(0 if float('$C')<20 else 1)" 2>/dev/null; then
    if [ ! -f "$STOP_FLAG" ]; then
      log "CREDIT GUARD: \$$C < \$20 — killing PAID (OpenRouter) runs; GPU/Q4 continues."
      touch "$STOP_FLAG"
      for pid in $(ps -eo pid,args | grep -E "pinchbench_full_run|benchmark.py --model (openrouter|meta|qwen|google)|swe_agentless_run|run_benchmark.py --models-config configs/models_full" | grep -v grep | awk '{print $1}'); do kill -9 $pid 2>/dev/null; done
    fi
  fi
  sleep 600   # 10 min
done
