#!/bin/bash
# FULL-PRECISION TerminalBench full-80: run the remaining 56 tasks (the 24-task stratified sample is
# already done) at the 2x timeout via OpenRouter, then MERGE base-24 + remaining-56 -> full-80
# results.json. Non-GPU, so all 5 models run in PARALLEL. Result -> results/terminalbench/<k>_full80/results.json
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO" || exit 1
# play-zork excluded (broken container -> guaranteed 404/timeout, wastes a slot). Full set = 24 + 55 = 79.
REM="$REPO/configs/terminal_remaining_noplayzork.txt"
LOG="$REPO/logs_tb80_full.log"
echo "=== tb80 full-precision (remaining-56 @2x, parallel) start $(date -u) ===" > "$LOG"
# base 24-task 2x run-ids (what the board currently reads)
declare -A BASE=( [qwen38]=or2x [qwen27]=qwen272x [qwen35]=qwen352x [gemma]=gemma2x [muse]=muse2x )
run_one(){
  local k="$1" rid="${BASE[$1]}"
  local base="$REPO/results/terminalbench/${k}_2x_full/${rid}/results.json"
  local remdir="$REPO/results/terminalbench/${k}_2x_full"
  echo "[$k] remaining-55 @2x start $(date -u)" >> "$LOG"
  # run-id MUST differ from the Q4 run-id (${k}q56) — identical run-ids build identically-named Docker
  # containers (<task>-1-of-1-<run-id>) and the two runs delete each other's containers -> 404.
  TB_OUT="$remdir" TB_RUNID="${k}f56" TB_MULT=2.0 TB_SAMPLE_FILE="$REM" \
    bash scripts/terminalbench_run.sh "$k" >> "$REPO/logs_tb80_full_${k}.log" 2>&1 \
    || echo "[$k] full remaining-55 non-zero" >> "$LOG"
  local extra="$remdir/${k}f56/results.json"
  mkdir -p "$REPO/results/terminalbench/${k}_full80"
  python3 scripts/tb_merge80.py "$base" "$extra" "$REPO/results/terminalbench/${k}_full80/results.json" >> "$LOG" 2>&1 \
    || echo "[$k] merge failed" >> "$LOG"
  echo "[$k] done $(date -u)" >> "$LOG"
}
for k in qwen38 qwen27 qwen35 gemma muse; do run_one "$k" & sleep 5; done
wait
echo "=== tb80 full-precision COMPLETE $(date -u) ===" >> "$LOG"
