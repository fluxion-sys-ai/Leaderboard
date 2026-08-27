#!/bin/bash
# tb_2x_q4_rest.sh — Q4 terminal-bench @2× for the 4 non-qwen38 models on the LOCAL GPU, sequentially
# (one llama-server / one model at a time — GPU can't share). qwen38 Q4 already done (gpu2x). Order:
# muse → qwen27 → qwen35 → gemma. Each: run the 24-task sample @2× into a distinct side dir/run-id,
# infra-backfill its container-race tasks, rebuild the board. When ALL 4 are done, RE-ENABLE the SWE GPU
# pipeline (.SWE_FULLSEL_ACTIVE) so SWE runs AFTER all Q4 terminal 2× — the whole point of the pause.
# Free (local GPU, no OpenRouter). Gated by .TB_2X_Q4REST_ACTIVE; watchdog respawns; resumable (skips
# models already at 24/24). Heads-up: full-precision showed 2× only helps qwen3.8, so these will likely
# be flat too — but this completes the Q4 side of the experiment.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO" || exit 1
LOG="$REPO/logs_tb_2x_q4_rest.log"
log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOG"; }
declare -A RID=( [muse]=museq2x [qwen27]=qwen27q2x [qwen35]=qwen35q2x [gemma]=gemmaq2x )
ORDER=(muse qwen27 qwen35 gemma)
done_k(){ local d="results/terminalbench_q4/${1}_2x24/${RID[$1]}/results.json"; [ -f "$d" ] && \
  [ "$(python3 -c "import json;x=json.load(open('$d'));print(x.get('n_resolved',0)+x.get('n_unresolved',0))" 2>/dev/null||echo 0)" -ge 24 ]; }

log "tb_2x_q4_rest up (pid $$) — Q4 @2× for ${ORDER[*]} (SWE paused until these finish)"
for k in "${ORDER[@]}"; do
  if done_k "$k"; then log "$k: already 24/24 — skip"; continue; fi
  log "=== $k Q4 @2× (run-id ${RID[$k]}) ==="
  env TB_MULT=2.0 TB_MAX_TOKENS=1000000 TB_RUNID="${RID[$k]}" TB_OUT="results/terminalbench_q4/${k}_2x24" \
    bash scripts/terminalbench_q4_run.sh "$k" >> "logs_tb_q4_${k}_2x.log" 2>&1 || log "$k: run returned non-zero"
  # NOTE: infra-backfill DISABLED per user rule — the 2× rerun must be a clean run, no backfills/regrades.
  # (was: tb_infra_backfill.sh q4 "$k" — re-ran container-race tasks and could shift the score.)
  python3 -m src.report.build_leaderboard >/dev/null 2>&1 && cp leaderboard.html docs/index.html 2>/dev/null
  log "$k: done ($(python3 -c "import json;d=json.load(open('results/terminalbench_q4/${k}_2x24/${RID[$k]}/results.json'));print(d.get('n_resolved',0),'/',d.get('n_resolved',0)+d.get('n_unresolved',0))" 2>/dev/null||echo '?'))"
done

# free the GPU server, then hand the GPU to SWE (user order: ALL Q4 terminal first, THEN SWE).
for p in $(pgrep -x llama-server); do kill -9 "$p" 2>/dev/null; done; sleep 3
log "all Q4 terminal 2× done — handing GPU to SWE"
touch "$REPO/.SWE_FULLSEL_ACTIVE"
alive(){ ps -eo args | grep -q "[b]ash scripts/swe_full_select_all.sh"; }
alive || setsid nohup bash scripts/swe_full_select_all.sh >> logs_swe_fullselect_all.log 2>&1 </dev/null & disown
rm -f "$REPO/.TB_2X_Q4REST_ACTIVE"
log "tb_2x_q4_rest exiting — SWE resumed after terminal"
