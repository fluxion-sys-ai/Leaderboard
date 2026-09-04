#!/bin/bash
# Respawn watchdog for the weekend automation — keeps every loop alive if its process dies,
# WITHOUT ever double-launching GPU work (the failure mode that caused the rogue-contamination bug).
#
# Safety rules:
#   * weekend_auto (board daemon) + swe_full_queue (OpenRouter, non-GPU) => respawn whenever down
#     and not complete. Zero GPU-contention risk.
#   * GPU chain scripts (qwen38_q4_seq / qwen38_chain / q4_agentic_queue / qwen38_full_ifaime) =>
#     respawn ONLY when down, not complete, the GPU is IDLE (no llama-server/vllm), and no other GPU
#     script is alive — and AT MOST ONE GPU launch per pass. So a crashed lane restarts, but two
#     GPU workers can never run at once.
#   * Liveness uses `ps -eo args | grep '[b]ash scripts/NAME.sh'` (exact bash-invocation match), so a
#     filename mentioned in some sibling command can't be misread as "running".
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
TERMN=$(grep -cE "[^[:space:]]" "$REPO/configs/terminal_sample.txt" 2>/dev/null || echo 80)  # stratified terminal sample size
log(){ echo "[$(date +'%F %T')] [watchdog] $*" >> "$REPO/logs_watchdog.log"; }
alive(){ ps -eo args | grep -q "[b]ash scripts/$1.sh"; }
gpu_idle(){ ! pgrep -f 'llama-server|vllm serve' >/dev/null; }
any_gpu_script(){ alive q4_agentic_queue; }   # the only remaining GPU worker (qwen38-full moved to OpenRouter)
# GPU lock: a manual/priority GPU run writes .gpu_lock (owner_pid\tname\trestart). While a LIVE owner
# holds it, the watchdog must NOT spawn q4_agentic (that's the "watchdog steals the GPU" bug). The
# gpu_guardian releases a stale lock when its owner dies, so this can't deadlock.
gpu_locked(){ [ -s "$REPO/.gpu_lock" ] && kill -0 "$(cut -f1 "$REPO/.gpu_lock" 2>/dev/null)" 2>/dev/null; }
spawn(){ nohup bash "scripts/$1.sh" >> "$REPO/logs_$1.log" 2>&1 & log "respawned $1 (pid $!)"; }

# --- per-script completion tests (true = work done, do NOT respawn) ---
sc(){ [ -f "results/scored/$1/$2.json" ]; }               # scored cell exists
term_done(){ local p="results/terminalbench_q4/$1/$1/results.json"; [ -f "$p" ] && [ "$(python3 -c "import json;d=json.load(open('$p'));print(d.get('n_resolved',0)+d.get('n_unresolved',0))" 2>/dev/null||echo 0)" -ge "$TERMN" ]; }
done_swe_full(){ sc muse-glimmer-30b-full swebench_lite && sc qwen3.6-27b-full swebench_lite && sc qwen3.6-35b-a3b-full swebench_lite && sc gemma-4-31b-full swebench_lite; }
# SWE cell counts as done only when scored over the FULL 51-instance stratified sample (n>=51). A cell
# still on the old 20-subset (n<51) => not done => queue respawns to finish it at strat51 (cached 20 +
# 31 new). Fail-safe: an unreadable/missing n reads as 0 (not done), EXCEPT a missing FILE is handled by
# the caller's `sc` first; here we only reach the count when the file exists.
swe51_done(){ local p="results/scored/$1/swebench_lite.json"; [ -f "$p" ] && \
  [ "$(python3 -c "import json;print(json.load(open('$p')).get('n',0))" 2>/dev/null||echo 0)" -ge 51 ]; }
done_agentic(){
  # Done only when EVERY Q4 cell is actually scored (not just when the queue logged COMPLETE once) —
  # so a cell that failed pre-fix gets the queue respawned to redo it (skip-guards skip the done ones).
  for m in gemma-4-31b-q4f qwen3.6-27b-q4f qwen3.5-35b-a3b-q4f qwen3.8-27b-q4f muse-glimmer-30b-q4f; do
    sc "$m" pinchbench && swe51_done "$m" || return 1
  done
  for k in gemma qwen27 qwen35 qwen38 muse; do term_done "$k" || return 1; done
  return 0
}
done_openrouter(){ sc qwen3.8-27b-full pinchbench && sc qwen3.8-27b-full swebench_lite \
                   && term_done_full qwen38; }   # NO ifbench/aime per user; terminal must be COMPLETE (>= sample size), not just exist
term_done_full(){ local p="results/terminalbench/$1/$1/results.json"; [ -f "$p" ] && [ "$(python3 -c "import json;d=json.load(open('$p'));print(d.get('n_resolved',0)+d.get('n_unresolved',0))" 2>/dev/null||echo 0)" -ge "$TERMN" ]; }
done_full_terminal(){ for k in muse qwen27 qwen35 gemma; do term_done_full "$k" || return 1; done; }
done_other4_pinch(){ for m in muse-glimmer-30b-full qwen3.6-27b-full qwen3.6-35b-a3b-full gemma-4-31b-full; do sc "$m" pinchbench || return 1; done; }

log "watchdog up (pid $$) — 5-min loop, GPU-mutex respawn."
while true; do
  date +%s > "$REPO/.watchdog_heartbeat"

  # 0) Docker network hygiene. Today's outage: "all predefined address pools have been fully
  #    subnetted" — orphaned per-task bridge networks piled up (from killed/parallel runs) until
  #    tb could no longer create a network, so EVERY task crashed instantly with unknown_agent_error.
  #    Prune unused networks each loop: it only removes networks NO container is attached to, so it
  #    can never touch a live task's network. `until=20m` also spares any network created in the last
  #    20 min, so even a mid-setup task (attached a beat later) can't be raced into a 404.
  docker network prune -f --filter until=20m >/dev/null 2>&1 || true

  # 1) non-GPU daemons/queues — always keep up (zero GPU-contention risk)
  alive weekend_auto || spawn weekend_auto
  alive gpu_guardian || spawn gpu_guardian   # keeps the GPU-lock supervisor alive (non-GPU; zero contention)
  alive gpu_night_keeper || spawn gpu_night_keeper   # keeps GPU busy all night: skip stalls + queue SWE->Q4-terminal
  alive smoke_sentinel || spawn smoke_sentinel  # number-sanity monitor + qwen3.8 IF/AIME resume guard (non-GPU)
  # Keep the full-80 backfill supervisor alive ONLY while the backfill is active (.TB_FULL80_ACTIVE).
  # It removes that flag on completion, so this won't respawn it afterward.
  if [ -f "$REPO/.TB_FULL80_ACTIVE" ]; then alive tb_full80_others || spawn tb_full80_others; fi
  if [ -f "$REPO/.TB_2X_ACTIVE" ]; then alive tb_2x_q4 || spawn tb_2x_q4; fi   # 24-task @2x Q4 orchestrator
  if [ -f "$REPO/.TB_2X_FULL_ACTIVE" ]; then alive tb_2x_full || spawn tb_2x_full; fi   # 24-task @2x full-precision orchestrator
  if [ -f "$REPO/.TB_2X_PAIR_ACTIVE" ]; then alive tb_2x_pair || spawn tb_2x_pair; fi   # paired GPU(gpu2x)+OpenRouter(or2x) @2x, distinct run-ids (no container collision)
  if [ -f "$REPO/.TB_2X_Q4REST_ACTIVE" ]; then alive tb_2x_q4_rest || spawn tb_2x_q4_rest; fi   # Q4 terminal 2x for the other 4 models (GPU), then re-enables SWE
  if [ ! -f "$REPO/.PAUSE_OPENROUTER" ] && [ -f "$REPO/.TB_2X_FULLALL_ACTIVE" ]; then alive tb_2x_full_all || spawn tb_2x_full_all; fi   # rolling-2 full-precision @2x on OpenRouter (credit-floored)
  if [ -f "$REPO/.TB_CAP_ALL_ACTIVE" ]; then alive tb_cap_all_q4 || spawn tb_cap_all_q4; fi   # all-5 Q4 terminal, native+cap
  if [ -f "$REPO/.SWE_Q4_RERUN_ACTIVE" ]; then alive swe_q4_rerun_all || spawn swe_q4_rerun_all; fi   # all-5 Q4 SWE fresh re-run (GPU)
  if [ -f "$REPO/.SWE_FULLSEL_ACTIVE" ]; then alive swe_full_select_all || spawn swe_full_select_all; fi   # all-5 full repro-test pipeline (GPU)
  if [ ! -f "$REPO/.PAUSE_OPENROUTER" ] && [ -f "$REPO/.SWE_OR_SELECT_ACTIVE" ]; then alive swe_or_select_all || spawn swe_or_select_all; fi   # OpenRouter full-precision repro-40 SWE, queued after OR terminal (credit-floored)
  if [ -f "$REPO/.SWE_Q4_AFTER_ACTIVE" ]; then alive swe_q4_after_2x || spawn swe_q4_after_2x; fi   # SWE Q4 majority-vote rescore, queued to start after gpu2x terminal 2x finishes
  if [ -f "$REPO/.SWE_Q4_NOW_ACTIVE" ]; then alive swe_q4_now || spawn swe_q4_now; fi   # SWE Q4 majority-vote, running NOW alongside terminal 2x (CPU+Docker only)
  # --- PAID OpenRouter spawns: HARD-GATED on .PAUSE_OPENROUTER (operator: "no more spend"). While
  #     that flag exists NONE of these can launch. GPU/Q4 (free, local) is unaffected below. ---
  if [ ! -f "$REPO/.PAUSE_OPENROUTER" ]; then
    if ! alive rec_pinch_full        && ! sc qwen3.8-27b-full pinchbench; then spawn rec_pinch_full; fi  # qwen3.8 pinch root — crash-resilient
    # full-precision SWE-Lite: all 5 models run in PARALLEL over OpenRouter, each in a -orf tagged
    # work dir (muse untagged) so they can't collide with the same models' Q4-LOCAL SWE (which share
    # the untagged results/swe_agentless/<key> dir). The guardian is idempotent: it promotes any
    # finished score onto the board + relaunches a dead run (resumes from cached structures/).
    bash scripts/full_swe_guardian.sh >> "$REPO/logs_full_swe_guardian.log" 2>&1
    if ! alive full_terminal_queue    && ! done_full_terminal && [ ! -f "$REPO/.TB_2X_FULL_ACTIVE" ]; then spawn full_terminal_queue;    fi
    if ! alive other4_pinch_queue     && ! done_other4_pinch && [ ! -f "$REPO/.PAUSE_OTHER4" ];   then spawn other4_pinch_queue;     fi
  fi

  # 2) GPU: only the Q4 queue remains (qwen38-full is on OpenRouter now). Respawn ONLY when the GPU
  # is idle, not paused, no GPU worker alive, and Q4 isn't already complete. The obsolete vLLM chain
  # (qwen38_chain / qwen38_full_seq / qwen38_full_ifaime / qwen38_q4_seq) is intentionally NOT spawned.
  if gpu_idle && ! any_gpu_script && ! gpu_locked && [ ! -f .PAUSE_MAIN_QUEUES ] && ! done_agentic; then
    spawn q4_agentic_queue
  fi

  # 3) STALL DETECTION — section 1/2 only respawn DEAD scripts. These catch ALIVE-but-HUNG, the
  #    real cause of unattended breakage. Conservative thresholds; never kill a task mid-progress.

  # 3a) tb post-completion hang: a terminal run is COMPLETE (results.json full, all 24 tasks scored)
  #     but its `tb` process is still alive >15min later — either wedged in --cleanup OR (seen 2026-08-24
  #     on qwen38) stuck generating on an already-finished run, holding the GPU. Once results.json shows
  #     dn>=exp, there is NOTHING legitimate left to do, so the ONLY reliable signal is the results.json
  #     mtime: if the completed results.json hasn't changed in 15min but tb is alive, it's hung. (The old
  #     check — "no file in the run-dir <10min" — was DEFEATED by the stuck generation writing fresh
  #     transcript files, so it never fired.) Results are already on disk; killing lets the wrapper advance.
  # SKIP this guard entirely while a FULL-80 terminal run is active: it has >24 tasks, so dn>=exp(24)
  # trips "complete", and a single native task can run 30min (results.json legitimately stale >15min) —
  # the guard would false-positive and kill the live full-80 run. The .TB_FULL80_ACTIVE flag gates it.
  for base in results/terminalbench_q4 results/terminalbench; do
    [ -f "$REPO/.TB_FULL80_ACTIVE" ] && break
    exp="$TERMN"   # both full + Q4 terminal now use the 24-task stratified sample
    for rj in "$base"/*/*/results.json; do
      [ -f "$rj" ] || continue
      k=$(basename "$(dirname "$(dirname "$rj")")")
      dn=$(python3 -c "import json;d=json.load(open('$rj'));print(d.get('n_resolved',0)+d.get('n_unresolved',0))" 2>/dev/null || echo 0)
      [ "$dn" -ge "$exp" ] || continue
      tbpid=$(pgrep -f "tb run .*$base/$k( |/|\$)" | head -1)   # EXACT dir ($k + space/slash/end); prefix match killed side-dir 2x runs (qwen38_2x24)
      [ -n "$tbpid" ] || continue
      # results.json is the completion marker: complete + not updated in 15min + tb still alive = hung.
      if [ -z "$(find "$rj" -newermt '-15 min' 2>/dev/null)" ]; then
        log "STALL: tb($tbpid) $k complete ($dn/$exp) but hung >15min (results.json stale, tb alive) -> killing + clearing containers"
        docker ps --format '{{.Names}}' 2>/dev/null | grep -- "-$k$" | xargs -r docker rm -f >/dev/null 2>&1
        kill -9 "$tbpid" 2>/dev/null
      fi
    done
  done

  # 3b) pinch wedge: benchmark.py alive but its log silent >35 min (thinking tasks are ~3 min each, so
  #     35 min of total silence = stuck OpenClaw session). Kill it; loop 1 respawns rec_pinch_full,
  #     which resumes from per-task cache. 35 min is generous to never cut a live task.
  # GATED on qwen38 pinch NOT yet scored — once scored (0.833), this guard is obsolete and must NOT
  # fire (it was reaping the intentional pinch-hfnt experiment, which also matches the pgrep pattern).
  if ! sc qwen3.8-27b-full pinchbench && pgrep -f "benchmark.py --model openrouter/qwen/qwen3.8-27b" >/dev/null 2>&1; then
    if [ -z "$(find logs_pb_rec_qwen38.log -newermt '-35 min' 2>/dev/null)" ]; then
      log "STALL: qwen3.8 pinch log silent >35min -> killing benchmark.py (rec_pinch_full will resume from cache)"
      pkill -9 -f "benchmark.py --model openrouter/qwen/qwen3.8-27b" 2>/dev/null
    fi
  fi

  # 3c) deploy guard: origin/main behind HEAD => push (belt-and-suspenders beyond weekend_auto's loop).
  AHEAD=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
  if [ "${AHEAD:-0}" -gt 0 ]; then
    timeout 90 git push origin main -q 2>/dev/null && log "deploy-guard: pushed $AHEAD commit(s) to origin"
  fi

  # 3d) GPU-wedge warning (log-only, no kill — SWE structure-caching can be legitimately quiet):
  #     a llama-server is up but GPU util ~0 and NO results written in 40 min. Surface it loudly.
  if pgrep -f 'llama-server' >/dev/null 2>&1; then
    util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [ "${util:-100}" -lt 5 ] && [ -z "$(find results -newermt '-40 min' -type f 2>/dev/null | head -1)" ]; then
      log "STALL-WARN: llama-server up but GPU idle(${util}%) + no results written in 40min — check GPU worker"
    fi
  fi

  # 3e) SWE localize infinite-hang guard: one --target_id localize call is a single model request
  #     (num_threads 1) — it finishes in minutes. temp0 + enable_thinking can send the model into a
  #     greedy repetition loop that never returns -> client 30-min timeout -> retries forever, pegging
  #     the GPU and blocking ALL of SWE-Lite (seen 2026-08-20 matplotlib-26011, 2h20m wasted). If a
  #     localize proc has run >35min on one target (past a full timeout cycle => provably looping, since
  #     --skip_existing means a done target is never re-run), kill it and append an empty-loc skip
  #     placeholder so --skip_existing advances the per-target loop. Never cuts a live task (a healthy
  #     single request never reaches 35min).
  while read -r lpid; do
    [ -n "$lpid" ] || continue
    el=$(ps -o etimes= -p "$lpid" 2>/dev/null | tr -d ' '); [ -n "$el" ] || continue
    [ "$el" -gt 2100 ] || continue
    largs=$(tr '\0' ' ' < "/proc/$lpid/cmdline" 2>/dev/null)
    tid=$(sed -n 's/.*--target_id \([^ ]*\).*/\1/p' <<<"$largs")
    ofolder=$(sed -n 's/.*--output_folder \([^ ]*\).*/\1/p' <<<"$largs")
    [ -n "$tid" ] && [ -n "$ofolder" ] || continue
    log "STALL: SWE localize($lpid) hung ${el}s on $tid (temp0+thinking greedy loop) -> kill + skip-placeholder"
    kill -9 "$lpid" 2>/dev/null
    python3 - "$ofolder/loc_outputs.jsonl" "$tid" <<'PY' 2>/dev/null
import json,sys,os
loc,tid=sys.argv[1],sys.argv[2]
rows=[json.loads(l) for l in open(loc)] if os.path.exists(loc) and os.path.getsize(loc) else []
if any(r.get('instance_id')==tid for r in rows): sys.exit(0)   # already succeeded; do nothing
keys=['instance_id','found_files','additional_artifact_loc_file','file_traj','found_related_locs','additional_artifact_loc_related','related_loc_traj','found_edit_locs','additional_artifact_loc_edit_location','edit_loc_traj']
if rows:
    tmpl=rows[-1]; new={k:([] if isinstance(v,list) else ("" if isinstance(v,str) else None)) for k,v in tmpl.items()}
else:
    new={k:None for k in keys}
new['instance_id']=tid
for f in ('found_files','found_related_locs','found_edit_locs'): new[f]=[]
new['_skipped_reason']='watchdog 3e: localize hung >35min (temp0+thinking greedy loop) auto-skipped'
open(loc,'a').write(json.dumps(new)+'\n')
PY
  done < <(pgrep -f 'agentless/fl/localize.py')

  sleep 300
done
