#!/bin/bash
# Q4 TerminalBench full-80: run the remaining 56 tasks (the 24-task sample is already done) at the 2x
# timeout on the local GPU, then MERGE base-24 + remaining-56 -> full-80 results.json. SERIAL — single
# GPU. Waits for any current GPU tb run + llama-server to clear first.
# Result -> results/terminalbench_q4/<k>_full80/results.json
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO" || exit 1
REM="$REPO/configs/terminal_sample_remaining.txt"
LOG="$REPO/logs_tb80_q4.log"
echo "=== tb80 Q4 (remaining-56 @2x, serial) start $(date -u) ===" > "$LOG"
# wait until the GPU is free. Only GPU USERS block us: a live llama-server, or a LOCAL-Q4 tb run
# (--model openai/edge-*-q4). OpenRouter tb runs (full-precision, --model openrouter/*) do NOT use the
# GPU, so we must NOT wait on them — otherwise the GPU sits idle for hours while OpenRouter runs.
gpu_busy(){ pgrep -x llama-server >/dev/null && return 0; pgrep -fa "[t]b run" 2>/dev/null | grep -q "openai/edge-.*-q4"; }
while gpu_busy; do
  echo "[wait] GPU busy (local Q4/llama-server), holding... $(date -u)" >> "$LOG"; sleep 60
done
echo "[wait] GPU free — starting Q4 full-80 sweep $(date -u)" >> "$LOG"
# base 24-task 2x run-ids (what the board currently reads)
declare -A BASE=( [qwen38]=gpu2x [muse]=museq2x [qwen27]=qwen27q2x [qwen35]=qwen35q2x [gemma]=gemmaq2x )
for k in qwen38 qwen27 qwen35 gemma muse; do
  rid="${BASE[$k]}"
  base="$REPO/results/terminalbench_q4/${k}_2x24/${rid}/results.json"
  outdir="$REPO/results/terminalbench_q4/${k}_2x24"
  echo "[$k] remaining-56 @2x start $(date -u)" >> "$LOG"
  TB_OUT="$outdir" TB_RUNID="${k}rem56" TB_MULT=2.0 TB_SAMPLE_FILE="$REM" TERMN=56 \
    bash scripts/terminalbench_q4_run.sh "$k" >> "$REPO/logs_tb80_q4_${k}.log" 2>&1 \
    || echo "[$k] q4 remaining-56 non-zero" >> "$LOG"
  extra="$outdir/${k}rem56/results.json"
  mkdir -p "$REPO/results/terminalbench_q4/${k}_full80"
  python3 scripts/tb_merge80.py "$base" "$extra" "$REPO/results/terminalbench_q4/${k}_full80/results.json" >> "$LOG" 2>&1 \
    || echo "[$k] merge failed" >> "$LOG"
  echo "[$k] done $(date -u)" >> "$LOG"
done
echo "=== tb80 Q4 COMPLETE $(date -u) ===" >> "$LOG"
