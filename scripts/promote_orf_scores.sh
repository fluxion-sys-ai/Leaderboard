#!/bin/bash
# Promote completed OpenRouter full-precision SWE scores from their tagged work dir into the
# board-visible dir. The 5 full-precision SWE runs are launched with `--tag orf` (separate work
# dirs) so they can't collide with the same models' Q4-local SWE runs (which share the untagged
# results/swe_agentless/<key> dir). A completed run writes results/scored/<FULLNAME>-full-orf/
# swebench_lite.json; the board reads results/scored/<FULLNAME>-full/. This moves the former to
# the latter (only when present + complete) so late-finishing runs land on the board automatically
# without babysitting, then rebuilds + deploys. Muse full SWE is launched WITHOUT a tag (no Q4
# collision risk for it in this batch) so it lands in -full directly and is not listed here.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO" || exit 1

# FULLNAME (board name) for each tagged OpenRouter full-SWE run
NAMES=(qwen3.8-27b qwen3.6-27b qwen3.6-35b-a3b gemma-4-31b)
moved=0
for n in "${NAMES[@]}"; do
  SRC="results/scored/${n}-full-orf/swebench_lite.json"
  DST_DIR="results/scored/${n}-full"
  DST="$DST_DIR/swebench_lite.json"
  [ -f "$SRC" ] || continue
  # completeness: a finished run has resolved+total written; skip half-written files
  ok=$(python3 -c "import json,sys;d=json.load(open('$SRC'));print(1 if 'resolved' in d and d.get('total',0)>0 else 0)" 2>/dev/null || echo 0)
  [ "$ok" = "1" ] || { echo "[promote] $n: -orf present but incomplete, skipping"; continue; }
  mkdir -p "$DST_DIR"
  mv -f "$SRC" "$DST"
  # also relocate the surrounding dir contents (patch, logs) if any, then drop the empty -orf scored dir
  rmdir "results/scored/${n}-full-orf" 2>/dev/null || true
  R=$(python3 -c "import json;d=json.load(open('$DST'));print(d.get('resolved','?'),'/',d.get('total','?'))" 2>/dev/null)
  echo "[promote] $n: promoted -orf -> -full ($R)"
  moved=$((moved+1))
done

if [ "$moved" -gt 0 ]; then
  echo "[promote] $moved score(s) promoted -> rebuilding + deploying board"
  bash scripts/weekend_auto.sh 2>/dev/null || true
else
  echo "[promote] nothing new to promote"
fi
exit 0
