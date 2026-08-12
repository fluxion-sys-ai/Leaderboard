#!/bin/bash
# Idempotent launcher for the overnight frontier sweep. Safe to call repeatedly
# (e.g. from the watchdog cron): starts the runner only if it isn't already up.
# Resumes from results/raw cache, so a restart never loses completed work.
set -u
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO" || exit 1

if pgrep -f "frontier_auto.py" >/dev/null 2>&1; then
  echo "frontier_auto already running (pid $(pgrep -f frontier_auto.py | head -1))"
  exit 0
fi

if [ ! -s .openrouter_key ]; then
  echo "ERROR: .openrouter_key missing/empty — cannot start"; exit 2
fi

export OPENROUTER_API_KEY="$(cat .openrouter_key)"
export PINCHBENCH_MODELS_FULL="$REPO/configs/models_full.yaml"
export PINCHBENCH_OPENROUTER_KEY_FILE="$REPO/.openrouter_key"

nohup python3 scripts/frontier_auto.py \
  --benchmarks ifeval aime2026 --smoke-limit 5 \
  >> /tmp/frontier_full.log 2>&1 &
echo "started frontier_auto pid $!"
