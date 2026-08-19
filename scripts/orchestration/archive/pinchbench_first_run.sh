#!/bin/bash
# PinchBench FIRST PRIORITY on ALL usable models (per shujun 2026-07-30), then the
# batched benchmarks, then judges/rescore/build. Smoke-gated; imports + rebuilds the
# leaderboard after EACH PinchBench model so results land incrementally (not after 2 days).
set -u
cd /home/aliixh/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token)"
LOG=/tmp/pinchbench_first.log

echo "[pb-first] start $(date -u +%T)" > $LOG
pkill -f 'llama-b9892/llama-server' 2>/dev/null; sleep 5     # ensure GPU is clear

MODELS=$(python3 scripts/top_models.py 6 | tr '\n' ' ')       # PinchBench: TOP 6 only (shujun 2026-07-30)
BATCH_MODELS=$(python3 scripts/top_models.py 15 | tr '\n' ' ')   # batched benchmarks: all 15 usable
echo "[pb-first] PinchBench models (top-6): $MODELS" >> $LOG

# ===== PinchBench FIRST (top 6, 116-task suite, smoke-gated) =====
FIRST=$(echo $MODELS | awk '{print $1}')
echo "[pb-first] PinchBench SMOKE on $FIRST $(date -u +%T)" >> $LOG
bash scripts/pinchbench_run.sh "$FIRST" >> $LOG 2>&1 || echo "[pb-first] smoke errored" >> $LOG
python3 import_pinchbench.py >> $LOG 2>&1
PB_OK=$(python3 -c "import json,os;p='results/scored/$FIRST/pinchbench.json';print('yes' if os.path.exists(p) and json.load(open(p)).get('score') is not None else 'no')" 2>/dev/null)
if [ "$PB_OK" = "yes" ]; then
  echo "[pb-first] smoke PASSED (real timing above) -> running the rest $(date -u +%T)" >> $LOG
  python3 -m src.report.build_leaderboard >> $LOG 2>&1
  for M in $MODELS; do
    [ "$M" = "$FIRST" ] && continue
    echo "[pb-first] PinchBench: $M $(date -u +%T)" >> $LOG
    bash scripts/pinchbench_run.sh "$M" >> $LOG 2>&1 || echo "[pb-first] $M failed" >> $LOG
    pkill -f 'llama-b9892/llama-server' 2>/dev/null; sleep 15
    python3 import_pinchbench.py >> $LOG 2>&1
    python3 -m src.report.build_leaderboard >> $LOG 2>&1   # leaderboard updates as each lands
    cp -f leaderboard.html /home/aliixh/edge_leaderboard.html 2>/dev/null
  done
else
  echo "[pb-first] !! smoke FAILED again — PinchBench harness still broken; skipping to batched." >> $LOG
fi
echo "[pb-first] PinchBench phase done $(date -u +%T)" >> $LOG

# ===== Batched benchmarks (all usable, model-outer) =====
echo "[pb-first] batched: pinchbench_clawd ruler simpleqa gpqa_diamond x all 15 usable $(date -u +%T)" >> $LOG
python3 run_benchmark.py --models $BATCH_MODELS --benchmarks pinchbench_clawd ruler simpleqa gpqa_diamond >> $LOG 2>&1

# ===== Judges + rescore + final build =====
echo "[pb-first] judges + rescore + final leaderboard $(date -u +%T)" >> $LOG
python3 judge_writing.py                                        >> $LOG 2>&1
python3 judge_simpleqa.py                                       >> $LOG 2>&1
python3 import_pinchbench.py                                    >> $LOG 2>&1
/home/aliixh/scorer-env/bin/python score_official.py humaneval  >> $LOG 2>&1
python3 rescore_all.py                                          >> $LOG 2>&1
python3 -m src.report.build_leaderboard                         >> $LOG 2>&1
cp -f leaderboard.html /home/aliixh/edge_leaderboard.html 2>/dev/null
echo "[pb-first] ALL DONE $(date -u +%T)" >> $LOG
