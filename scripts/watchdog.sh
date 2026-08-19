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
any_gpu_script(){ for s in qwen38_q4_seq qwen38_chain qwen38_full_seq q4_agentic_queue qwen38_full_ifaime; do alive "$s" && return 0; done; return 1; }
spawn(){ nohup bash "scripts/$1.sh" >> "$REPO/logs_$1.log" 2>&1 & log "respawned $1 (pid $!)"; }

# --- per-script completion tests (true = work done, do NOT respawn) ---
sc(){ [ -f "results/scored/$1/$2.json" ]; }               # scored cell exists
term_done(){ local p="results/terminalbench_q4/$1/$1/results.json"; [ -f "$p" ] && [ "$(python3 -c "import json;d=json.load(open('$p'));print(d.get('n_resolved',0)+d.get('n_unresolved',0))" 2>/dev/null||echo 0)" -ge "$TERMN" ]; }
done_swe_full(){ sc muse-glimmer-30b-full swebench_lite && sc qwen3.6-27b-full swebench_lite && sc qwen3.6-35b-a3b-full swebench_lite && sc gemma-4-31b-full swebench_lite; }
done_q4seq(){ sc qwen3.8-27b-q4f pinchbench && sc qwen3.8-27b-q4f swebench_lite && term_done qwen38; }
done_chain(){ [ -f .QWEN38_DONE ]; }
done_agentic(){
  # Done only when EVERY Q4 cell is actually scored (not just when the queue logged COMPLETE once) —
  # so a cell that failed pre-fix gets the queue respawned to redo it (skip-guards skip the done ones).
  for m in gemma-4-31b-q4f qwen3.6-27b-q4f qwen3.5-35b-a3b-q4f qwen3.8-27b-q4f muse-glimmer-30b-q4f; do
    sc "$m" pinchbench && sc "$m" swebench_lite || return 1
  done
  for k in gemma qwen27 qwen35 qwen38 muse; do term_done "$k" || return 1; done
  return 0
}
done_ifaime(){ sc qwen3.8-27b-full ifbench && sc qwen3.8-27b-full aime2026; }

log "watchdog up (pid $$) — 5-min loop, GPU-mutex respawn."
while true; do
  date +%s > "$REPO/.watchdog_heartbeat"

  # 1) non-GPU daemons — always keep up
  alive weekend_auto   || spawn weekend_auto
  if ! alive swe_full_queue && ! done_swe_full; then spawn swe_full_queue; fi

  # 2) GPU chain — at most ONE launch per pass, only when the GPU is genuinely idle AND not paused
  # (.PAUSE_MAIN_QUEUES is set during manual GPU maintenance; without this check the watchdog raced
  # a manual full_seq relaunch and spawned a competing Q4 llama-server -> vLLM OOM).
  if gpu_idle && ! any_gpu_script && [ ! -f .PAUSE_MAIN_QUEUES ]; then
    if   ! done_q4seq   ; then spawn qwen38_q4_seq
    elif ! done_chain   ; then spawn qwen38_chain
    elif ! done_agentic ; then spawn q4_agentic_queue
    elif ! done_ifaime  ; then spawn qwen38_full_ifaime
    fi
  fi

  sleep 300
done
