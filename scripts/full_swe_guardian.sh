#!/bin/bash
# Guardian for the 5 parallel full-precision (OpenRouter) SWE-bench Lite runs. Replaces the old
# sequential swe_full_queue.sh (which ran one model at a time, ~10h wall-clock, and wedged). These
# 5 runs are launched concurrently over OpenRouter — no GPU contention, independent scores.
#
# For each model: if the board-visible -full score exists -> done. Else if the run's scored output
# exists (in its -orf tagged dir, or -full for muse) -> promote onto the board. Else if the run
# process is not alive -> relaunch it (localize is cached via structures/, so a relaunch resumes
# cheaply rather than restarting from scratch). Idempotent + safe to call every watchdog tick.
#
# Tagging: qwen38/qwen27/qwen35/gemma use `--tag orf` (separate work dir) so they can't collide
# with the same models' Q4-LOCAL SWE runs that share results/swe_agentless/<key>. Muse has no Q4
# SWE queued in this batch, so it runs untagged and lands in -full directly.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO" || exit 1

# key : board-fullname : tag ("" = untagged)
RUNS=(
  "muse:muse-glimmer-30b:"
  "qwen38:qwen3.8-27b:orf"
  "qwen27:qwen3.6-27b:orf"
  "qwen35:qwen3.6-35b-a3b:orf"
  "gemma:gemma-4-31b:orf"
)

moved=0
for row in "${RUNS[@]}"; do
  IFS=: read -r key full tag <<<"$row"
  FULL_JSON="results/scored/${full}-full/swebench_lite.json"
  # board score already present + complete -> nothing to do
  if [ -f "$FULL_JSON" ] && python3 -c "import json,sys;d=json.load(open('$FULL_JSON'));sys.exit(0 if 'resolved' in d and d.get('total',0)>0 else 1)" 2>/dev/null; then
    continue
  fi
  # scored output sitting in the tagged dir -> promote onto the board
  if [ -n "$tag" ]; then
    SRC="results/scored/${full}-full-${tag}/swebench_lite.json"
    if [ -f "$SRC" ] && python3 -c "import json,sys;d=json.load(open('$SRC'));sys.exit(0 if 'resolved' in d and d.get('total',0)>0 else 1)" 2>/dev/null; then
      mkdir -p "results/scored/${full}-full"
      mv -f "$SRC" "$FULL_JSON"
      rmdir "results/scored/${full}-full-${tag}" 2>/dev/null || true
      R=$(python3 -c "import json;d=json.load(open('$FULL_JSON'));print(d.get('resolved','?'),'/',d.get('total','?'))" 2>/dev/null)
      echo "[full-swe] $key: promoted -${tag} -> board ($R)"
      moved=$((moved+1))
      continue
    fi
  fi
  # not scored yet: if the run process died, relaunch (resumes from cached structures/localize)
  if ! ps -eo args | grep -q "[s]we_agentless_run.sh $key"; then
    TAGARG=(); [ -n "$tag" ] && TAGARG=(--tag "$tag")
    setsid bash scripts/swe_agentless_run.sh "$key" --subset strat50 "${TAGARG[@]}" \
      >> "logs_swe_full_${key}${tag:+_$tag}.log" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    echo "[full-swe] $key: run not alive + not scored -> relaunched${tag:+ (--tag $tag)}"
  fi
done

if [ "$moved" -gt 0 ]; then
  echo "[full-swe] $moved score(s) promoted -> rebuild + deploy board"
  bash scripts/weekend_auto.sh 2>/dev/null || true
fi
exit 0
