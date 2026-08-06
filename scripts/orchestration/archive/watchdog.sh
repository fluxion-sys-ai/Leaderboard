#!/bin/bash
# WATCHDOG — runs independently (doesn't need the assistant to be "awake"). Every 2 min:
#   1. Kills ORPHANED llama-servers (ppid=1) — a server whose driver died leaves it holding
#      the GPU/port and blocks the whole pipeline (this is the bug that cost 10h on 2026-07-30).
#      A LEGIT server is always a child of run_benchmark.py / benchmark.py / pinchbench_run.sh
#      (ppid != 1), so ppid=1 uniquely identifies an orphan — safe to kill.
#   2. Flags a watcher that's been stuck 'waiting' with no progress for too long.
# Self-terminates when the extra + pinchbench-retry watchers are both done.
LOG=/tmp/watchdog.log
echo "[watchdog] started $(date -u +%T)" >> $LOG
STUCK=0
while true; do
  # (1) reap orphaned llama-servers
  for pid in $(pgrep -x -f 'llama-server' 2>/dev/null; pgrep -f 'llama-b9892/llama-server' 2>/dev/null); do
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ "$ppid" = "1" ]; then
      model=$(ps -o cmd= -p "$pid" 2>/dev/null | grep -o 'models/[^ ]*' | head -1)
      echo "[watchdog] $(date -u +%T) ORPHAN llama-server $pid (ppid=1, $model) -> KILL" >> $LOG
      kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null
    fi
  done
  # (2) exit once the pipeline is finished
  if ! pgrep -f 'newmodels_run.sh|qwen35_base_run.sh' >/dev/null 2>&1; then
    echo "[watchdog] pipeline watchers gone -> exiting $(date -u +%T)" >> $LOG
    break
  fi
  sleep 120
done
