#!/bin/bash
# gpu_guardian.sh — keeps the single local GPU (llama-server on :8081) from "dying" under a run,
# and stops the watchdog/queues from stealing it. Standalone daemon; launch detached with setsid.
#
# HOW IT WORKS — a lock file + a supervisor loop:
#   .gpu_lock  (TSV, one line):  <owner_pid>\t<human_name>\t<server_restart_cmd>
#     * A GPU run WRITES this when it takes the GPU (see gpu_lock_acquire below / callers).
#     * The watchdog's q4 gate REFUSES to spawn q4_agentic while a live foreign lock is held
#       (see watchdog.sh section "GPU lock"), so nothing steals a running job.
#   Every 30s the guardian:
#     1. owner ALIVE + server DOWN  -> restart the server it needs (the "GPU died" case).
#     2. owner DEAD (run crashed/finished) -> release the lock so the normal tail can resume
#        (prevents "GPU idle forever after a crash").
#     3. owner ALIVE + GPU idle a long time -> WARN only (localize/eval phases legitimately idle
#        the GPU, so we never kill on idle alone).
#
# SAFE BY DESIGN: it only STARTS a server / RELEASES a stale lock; it never kills a live run.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO" || exit 1
LOCK="$REPO/.gpu_lock"
PORT=8081
LOG="$REPO/logs_gpu_guardian.log"
log(){ echo "[$(date +'%F %T')] [gpu-guardian] $*" >> "$LOG"; }
server_up(){ timeout 6 curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; }
gpu_util(){ nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1; }

log "gpu-guardian up (pid $$) — 30s loop"
idle_since=0
while true; do
  date +%s > "$REPO/.gpu_guardian_heartbeat"
  if [ -f "$LOCK" ]; then
    owner=$(cut -f1 "$LOCK" 2>/dev/null)
    name=$(cut -f2 "$LOCK" 2>/dev/null)
    restart=$(cut -f3- "$LOCK" 2>/dev/null)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      # (1) owner alive -> the server MUST stay up. Restart it if it died.
      if ! server_up; then
        if [ -n "$restart" ]; then
          # don't double-start: only if nothing is already listening on the port
          if [ -z "$(ss -tln 2>/dev/null | grep ":$PORT")" ]; then
            log "server DOWN under live owner $owner ($name) -> restarting: $restart"
            setsid bash -c "$restart" >> "$REPO/logs_gpu_guardian_server.log" 2>&1 < /dev/null &
            for _i in $(seq 1 30); do server_up && break; sleep 2; done
            server_up && log "server back UP for $name" || log "server restart did NOT come up (will retry next pass)"
          fi
        else
          log "server DOWN under $owner ($name) but no restart cmd in lock — cannot auto-recover"
        fi
      fi
      # (3) idle WARN only (never kill on idle — localize/eval legitimately idle the GPU)
      u=$(gpu_util)
      if [ "${u:-100}" -lt 3 ]; then
        [ "$idle_since" = 0 ] && idle_since=$(date +%s)
        el=$(( $(date +%s) - idle_since ))
        if [ "$el" -gt 1200 ]; then
          log "WARN: GPU idle ${el}s while $name ($owner) holds the lock — likely a legit localize/eval phase, but check for a stall."
          idle_since=$(date +%s)   # re-arm so it warns at most every 20 min
        fi
      else
        idle_since=0
      fi
    else
      # (2) owner gone -> run crashed or finished. Release the lock so the tail resumes; the GPU
      #     won't sit dead. We do NOT kill the (orphaned) server here — the next GPU job's wrapper
      #     handles the port (its own guard), and releasing the lock lets the watchdog proceed.
      log "lock owner ${owner:-?} ($name) is GONE -> releasing .gpu_lock (run crashed or finished)"
      rm -f "$LOCK"
      idle_since=0
    fi
  else
    idle_since=0
  fi
  sleep 30
done
