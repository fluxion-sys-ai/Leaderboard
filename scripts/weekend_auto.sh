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
  # Deploy — UNGATED (was gated on `git diff --quiet docs/index.html`, which stranded staged changes
  # forever once a byte-identical rebuild made that gate false, and skipped the push too). Now: always
  # stage board files best-effort (unmatched score globs can't block), commit iff something is actually
  # staged (index-vs-HEAD, not unstaged-only), and ALWAYS push whenever local is ahead of origin.
  # Stale-lock guard: a prior `timeout 30 git ...` that got KILLED mid-op can leave .git/index.lock,
  # which then fails EVERY subsequent commit ("commit failed" loop). If no git is actually running and
  # the lock is >2 min old, it's stale -> remove it so commits recover.
  if [ -f .git/index.lock ] && ! pgrep -x git >/dev/null 2>&1; then
    find .git/index.lock -mmin +2 -delete 2>/dev/null && log "removed stale .git/index.lock"
  fi
  timeout 60 git add docs/index.html leaderboard.html 2>/dev/null || true
  # Stage ALL scored cells as source-of-truth (the HTML already renders them; this versions the raw
  # scores too so the repo fully reflects the board): pinch, swe, ifbench, aime, terminal_bench.
  timeout 30 git add results/scored/*/pinchbench.json 2>/dev/null || true
  timeout 30 git add results/scored/*/swebench_lite.json 2>/dev/null || true
  timeout 30 git add results/scored/*/ifbench.json 2>/dev/null || true
  timeout 30 git add results/scored/*/aime2026.json 2>/dev/null || true
  timeout 30 git add results/terminalbench*/*/*/results.json 2>/dev/null || true
  timeout 30 git add results/scored/*/terminal_full.json 2>/dev/null || true   # full-80 terminal scores
  if ! git diff --cached --quiet 2>/dev/null; then
    # log the REAL error (was hidden by 2>/dev/null, which turned every failure into an opaque
    # "commit failed" with no cause). Longer timeout so a big index can't get killed mid-commit.
    if timeout 60 git -c user.name="aliixh" -c user.email="aliixhuang@gmail.com" commit -q -m "leaderboard: auto-refresh" 2>>"$LOG"; then log "board committed"; else log "commit failed (see error above)"; fi
  fi
  AHEAD=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
  if [ "${AHEAD:-0}" -gt 0 ]; then
    if timeout 90 git push origin main -q 2>>"$LOG"; then log "board pushed ($AHEAD commit(s))"; else log "PUSH FAILED/timed-out (will retry next pass)"; fi
  fi
  C=$(credits)
  if [ -n "$C" ] && python3 -c "import sys;sys.exit(0 if float('$C')<5 else 1)" 2>/dev/null; then
    if [ ! -f "$STOP_FLAG" ]; then
      log "CREDIT GUARD: \$$C < \$5 — killing PAID (OpenRouter) runs; GPU/Q4 continues."
      touch "$STOP_FLAG"
      for pid in $(ps -eo pid,args | grep -E "pinchbench_full_run|benchmark.py --model (openrouter|meta|qwen|google)|swe_agentless_run|run_benchmark.py --models-config configs/models_full|tb run .*terminalbench/" | grep -v grep | awk '{print $1}'); do kill -9 $pid 2>/dev/null; done
    fi
  fi
  sleep 600   # 10 min
done
