#!/bin/bash
# Post-pass for ALL models: the reasoning models intermittently return content:null with
# finish_reason:length on long terminal turns -> litellm "data must be str, not NoneType" -> some tasks
# die as unknown_agent_error. qwen35 (-a3b) is worst-hit but muse/gemma can too. The null is
# INTERMITTENT (verified: direct probes all return content), so a plain retry of just the failed
# task-ids recovers them WITHOUT any param change (keeps base-24 <-> remaining-55 merge consistent).
# Reruns into a DISTINCT run-id (<k>r1) so it never shares Docker container names with the main run
# (the collision rule). Then re-merges so retried tasks win. Each model heals independently as its
# lane finishes; per-model done-flag makes it once-only. Self-gating + reboot-durable via cron.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO" || exit 1
LOG="$REPO/logs_tb80_retry.log"
exec >>"$LOG" 2>&1
echo "=== null-retry sweep $(date -u) ==="

declare -A BASE=( [qwen38]=or2x [qwen27]=qwen272x [qwen35]=qwen352x [gemma]=gemma2x [muse]=muse2x )

for k in qwen38 qwen27 qwen35 gemma muse; do
  MAINRUN="$REPO/results/terminalbench/${k}_2x_full/${k}f56"
  DONEFLAG="$REPO/.${k}_retry_done"
  [ -f "$DONEFLAG" ] && continue                                   # already handled
  pgrep -f "${k}f56" >/dev/null 2>&1 && { echo "[$k] main run live -> defer"; continue; }
  pgrep -f "${k}r1"  >/dev/null 2>&1 && { echo "[$k] retry already running -> skip (avoid r1 collision)"; continue; }
  [ -d "$MAINRUN" ] || { echo "[$k] no run dir yet -> defer"; continue; }

  mapfile -t TASKS < <(grep -rl "unknown_agent_error" "$MAINRUN" 2>/dev/null \
    | xargs -r -n1 dirname | xargs -r -n1 basename | sed 's/\.1-of-1.*//' \
    | grep -v "^${k}f56$" | sort -u)
  if [ "${#TASKS[@]}" -eq 0 ]; then echo "[$k] no null-failures, nothing to retry"; touch "$DONEFLAG"; continue; fi
  echo "[$k] retrying null-failed tasks: ${TASKS[*]}"

  printf '%s\n' "${TASKS[@]}" > "$REPO/configs/_${k}_retry_tasks.txt"
  TB_OUT="$REPO/results/terminalbench/${k}_2x_full" TB_RUNID="${k}r1" TB_MULT=2.0 \
    TB_SAMPLE_FILE="$REPO/configs/_${k}_retry_tasks.txt" \
    bash scripts/terminalbench_run.sh "$k" || echo "[$k] retry run non-zero (continuing to merge)"

  BASE_J="$REPO/results/terminalbench/${k}_2x_full/${BASE[$k]}/results.json"
  REM_J="$MAINRUN/results.json"
  RETRY_J="$REPO/results/terminalbench/${k}_2x_full/${k}r1/results.json"
  FULL80="$REPO/results/terminalbench/${k}_full80/results.json"
  mkdir -p "$(dirname "$FULL80")"
  python3 scripts/tb_merge80.py "$BASE_J" "$REM_J" "$FULL80" && \
  python3 scripts/tb_merge80.py "$FULL80" "$RETRY_J" "$FULL80" && \
  echo "[$k] re-merged full80 with retried tasks"
  touch "$DONEFLAG"
done
echo "=== null-retry sweep done $(date -u) ==="
