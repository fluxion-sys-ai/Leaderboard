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
done_agentic(){
  # Done only when EVERY Q4 cell is actually scored (not just when the queue logged COMPLETE once) —
  # so a cell that failed pre-fix gets the queue respawned to redo it (skip-guards skip the done ones).
  for m in gemma-4-31b-q4f qwen3.6-27b-q4f qwen3.5-35b-a3b-q4f qwen3.8-27b-q4f muse-glimmer-30b-q4f; do
    sc "$m" pinchbench && sc "$m" swebench_lite || return 1
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

  # 1) non-GPU daemons/queues — always keep up (zero GPU-contention risk)
  alive weekend_auto || spawn weekend_auto
  alive gpu_guardian || spawn gpu_guardian   # keeps the GPU-lock supervisor alive (non-GPU; zero contention)
  if ! alive rec_pinch_full        && ! sc qwen3.8-27b-full pinchbench; then spawn rec_pinch_full; fi  # qwen3.8 pinch root — crash-resilient
  if ! alive swe_full_queue        && ! done_swe_full;  then spawn swe_full_queue;        fi
  if ! alive qwen38_full_openrouter && ! done_openrouter; then spawn qwen38_full_openrouter; fi
  if ! alive full_terminal_queue    && ! done_full_terminal; then spawn full_terminal_queue;    fi
  if ! alive other4_pinch_queue     && ! done_other4_pinch;   then spawn other4_pinch_queue;     fi

  # 2) GPU: only the Q4 queue remains (qwen38-full is on OpenRouter now). Respawn ONLY when the GPU
  # is idle, not paused, no GPU worker alive, and Q4 isn't already complete. The obsolete vLLM chain
  # (qwen38_chain / qwen38_full_seq / qwen38_full_ifaime / qwen38_q4_seq) is intentionally NOT spawned.
  if gpu_idle && ! any_gpu_script && ! gpu_locked && [ ! -f .PAUSE_MAIN_QUEUES ] && ! done_agentic; then
    spawn q4_agentic_queue
  fi

  # 3) STALL DETECTION — section 1/2 only respawn DEAD scripts. These catch ALIVE-but-HUNG, the
  #    real cause of unattended breakage. Conservative thresholds; never kill a task mid-progress.

  # 3a) tb --cleanup post-completion hang: a terminal run is COMPLETE (results.json full) but its `tb`
  #     process is still alive and the run-dir has been quiet >10 min => wedged in --cleanup on an
  #     undead container, holding the GPU idle. Kill it so the wrapper advances. Results already on disk.
  for base in results/terminalbench_q4 results/terminalbench; do
    exp="$TERMN"   # both full + Q4 terminal now use the 24-task stratified sample
    for rj in "$base"/*/*/results.json; do
      [ -f "$rj" ] || continue
      k=$(basename "$(dirname "$(dirname "$rj")")")
      dn=$(python3 -c "import json;d=json.load(open('$rj'));print(d.get('n_resolved',0)+d.get('n_unresolved',0))" 2>/dev/null || echo 0)
      [ "$dn" -ge "$exp" ] || continue
      tbpid=$(pgrep -f "tb run .*$base/$k($|[^0-9])" | head -1)
      [ -n "$tbpid" ] || continue
      if [ -z "$(find "$base/$k" -newermt '-10 min' -type f 2>/dev/null | head -1)" ]; then
        log "STALL: tb($tbpid) $k complete ($dn/$exp) but hung >10min in cleanup -> killing + clearing containers"
        docker ps --format '{{.Names}}' 2>/dev/null | grep -- "-of-1-$k$" | xargs -r docker rm -f >/dev/null 2>&1
        kill -9 "$tbpid" 2>/dev/null
      fi
    done
  done

  # 3b) pinch wedge: benchmark.py alive but its log silent >35 min (thinking tasks are ~3 min each, so
  #     35 min of total silence = stuck OpenClaw session). Kill it; loop 1 respawns rec_pinch_full,
  #     which resumes from per-task cache. 35 min is generous to never cut a live task.
  if pgrep -f "benchmark.py --model openrouter/qwen/qwen3.8-27b" >/dev/null 2>&1; then
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
