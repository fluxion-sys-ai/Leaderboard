#!/bin/bash
# Follow-on: run EXTRA benchmarks after the main watcher (PID 1812216) finishes.
# ORDER (per shujun): PinchBench FIRST (the headline Agent metric), then the
# batched new benchmarks, then judges + leaderboard.
# SOLO-GPU SAFE: waits for main watcher AND every llama-server to be gone.
set -u
cd /home/aliixh/edge-intelligence-benchmark
export LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892
export HF_TOKEN="$(cat /home/aliixh/edge-intelligence-benchmark/.hf_token)"   # gated GPQA pull
LOG=/tmp/extra_benchmarks.log

echo "[extra] waiting for main watcher (PID 1812216) to finish... $(date -u +%T)" > $LOG
while kill -0 1812216 2>/dev/null; do sleep 60; done
echo "[extra] main watcher exited $(date -u +%T)" >> $LOG
while pgrep -f 'llama-server' >/dev/null 2>&1; do
  echo "[extra] llama-server still up, waiting... $(date -u +%T)" >> $LOG; sleep 30
done
echo "[extra] GPU free -> starting extras $(date -u +%T)" >> $LOG

# TOP 8 by Average (dynamic — reflects final standings incl. new models). Expensive
# extras (PinchBench, RULER, GPQA...) run only on the contenders, not the whole matrix.
MODELS=$(python3 scripts/top_models.py 8 | tr '\n' ' ')
echo "[extra] scoped to top-8 models: $MODELS" >> $LOG

# === Step 1 (FIRST PRIORITY): local PinchBench — the Agent-score metric =====
# SMOKE-GATE: run ONE model first, confirm it produced a valid pinchbench score, and
# only then commit to the remaining ~17 (each ~30-45min). Never grind 12h on a broken harness.
echo "[extra] Step 1/3: PinchBench (multi-turn agent) — smoke-gate first $(date -u +%T)" >> $LOG
FIRST=$(echo $MODELS | awk '{print $1}')
echo "[extra]   smoke: PinchBench on $FIRST $(date -u +%T)" >> $LOG
bash scripts/pinchbench_run.sh $FIRST >> $LOG 2>&1 || echo "[extra]   smoke run errored" >> $LOG
python3 import_pinchbench.py >> $LOG 2>&1
PB_OK=$(python3 -c "
import json,os
p='results/scored/$FIRST/pinchbench.json'
print('yes' if os.path.exists(p) and json.load(open(p)).get('score') is not None else 'no')" 2>/dev/null)
if [ "$PB_OK" = "yes" ]; then
  echo "[extra]   smoke PASSED -> running PinchBench on the rest $(date -u +%T)" >> $LOG
  for M in $MODELS; do
    [ "$M" = "$FIRST" ] && continue
    echo "[extra]   PinchBench: $M $(date -u +%T)" >> $LOG
    bash scripts/pinchbench_run.sh $M >> $LOG 2>&1 || echo "[extra]   $M FAILED — skipping" >> $LOG
    sleep 20
  done
  python3 import_pinchbench.py >> $LOG 2>&1
else
  echo "[extra]   !! smoke FAILED — PinchBench harness needs manual fix. Skipping rest of PinchBench, continuing." >> $LOG
fi
echo "[extra] Step 1 DONE $(date -u +%T)" >> $LOG

# === Step 2: NEW benchmarks across ALL models — BATCHED (model-outer) =============
# One pass so each model loads ONCE and runs all four, instead of reloading per benchmark.
echo "[extra] Step 2/3: pinchbench_clawd + ruler + simpleqa + gpqa_diamond (batched, top-8) $(date -u +%T)" >> $LOG
python3 run_benchmark.py --models $MODELS --benchmarks pinchbench_clawd ruler simpleqa gpqa_diamond >> $LOG 2>&1
echo "[extra] Step 2 DONE $(date -u +%T)" >> $LOG

# === Step 3: judges + rescore + rebuild leaderboard ===============================
echo "[extra] Step 3/3: judges + rescore + leaderboard $(date -u +%T)" >> $LOG
python3 judge_writing.py                                        >> $LOG 2>&1
python3 judge_simpleqa.py                                       >> $LOG 2>&1
python3 import_pinchbench.py                                    >> $LOG 2>&1
/home/aliixh/scorer-env/bin/python score_official.py humaneval  >> $LOG 2>&1
python3 rescore_all.py                                          >> $LOG 2>&1
python3 -m src.report.build_leaderboard                         >> $LOG 2>&1
cp -f leaderboard.html /home/aliixh/edge_leaderboard.html 2>/dev/null
echo "[extra] ALL DONE $(date -u +%T)" >> $LOG
