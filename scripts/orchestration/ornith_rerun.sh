#!/bin/bash
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/ornith_rerun.log
say(){ echo "[ornith] $(date -u +%T) $*" >> "$L"; }
echo "=== ornith re-run (no_think fix) + final judge sweep ===" > "$L"
BENCH="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl simpleqa"

# run truly last: wait for stage2 AND qwen-fix to finish, and no model inference active
say "waiting for stage2 + qwen-fix to finish"
while ps -eo cmd | grep -qE "bash /tmp/stage2_newmodels\.sh$" \
   || pgrep -f "run_benchmark.py --models" >/dev/null \
   || pgrep -f "benchmark.py --model openai/edge-" >/dev/null; do sleep 300; done
say "GPU free -> re-running ornith with no_think"

pkill -f 'llama-server' 2>/dev/null; sleep 8
# clear ONLY the contaminated results (keep the GGUF to avoid a re-download)
rm -rf results/scored/ornith-1.0-9b results/raw/ornith-1.0-9b
say "ornith grid (no_think now on)"
python3 run_benchmark.py --models ornith-1.0-9b --benchmarks $BENCH >> "$L" 2>&1 || say "ornith grid errored"
if ls results/scored/ornith-1.0-9b/*.json >/dev/null 2>&1; then
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  say "ornith PinchBench (6th-best gate + clamp-guard decide)"
  bash scripts/pinchbench_run.sh ornith-1.0-9b >> "$L" 2>&1 || say "ornith pinchbench skipped/errored"
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  python3 import_pinchbench.py >> "$L" 2>&1
else
  say "!! ornith produced NO grid scores — flag."
fi

# FINAL judge sweep — scores writing/simpleqa for everyone still pending (exaone/gpt-oss/gemma/ornith)
say "final judge sweep (writing + simpleqa)"
python3 judge_writing.py  >> "$L" 2>&1
python3 judge_simpleqa.py >> "$L" 2>&1
python3 rescore_all.py    >> "$L" 2>&1
python3 -m src.report.build_leaderboard >> "$L" 2>&1
cp -f leaderboard.html /home/ubuntu/.openclaw/workspace/leaderboard.html 2>/dev/null
say "ORNITH RE-RUN + FINAL JUDGE DONE"
