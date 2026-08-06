#!/bin/bash
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/gemma_last.log
say(){ echo "[gemma-last] $(date -u +%T) $*" >> "$L"; }
echo "=== gemma-4-31b (bonus) — runs dead last ===" > "$L"
BENCH="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl simpleqa"

# wait for EVERYTHING else (stage2, qwen-fix, ornith) to finish
say "waiting for stage2 + qwen-fix + ornith to all finish"
while ps -eo cmd | grep -qE "bash /tmp/(stage2_newmodels|ornith_rerun|qwen_128k_fix|gptoss_medium)\.sh$" \
   || pgrep -f "run_benchmark.py --models" >/dev/null \
   || pgrep -f "benchmark.py --model openai/edge-" >/dev/null; do sleep 300; done
say "everything else done -> re-adding gemma to config"

# re-add gemma entry (append to end of the models list), then VERIFY parse before proceeding
if ! python3 -c "import yaml,sys; sys.exit(0 if 'gemma-4-31b' in [m['name'] for m in yaml.safe_load(open('configs/models.yaml'))['models']] else 1)" 2>/dev/null; then
  printf '\n' >> configs/models.yaml
  cat /tmp/gemma_entry.txt >> configs/models.yaml
fi
if ! python3 -c "import yaml; yaml.safe_load(open('configs/models.yaml'))" 2>/dev/null; then
  say "!! config broke on gemma re-add — ABORT (leaving everything else intact)"; exit 1
fi
say "config OK, gemma present -> running grid + pinchbench"

pkill -f 'llama-server' 2>/dev/null; sleep 8
python3 run_benchmark.py --models gemma-4-31b --benchmarks $BENCH >> "$L" 2>&1 || say "gemma grid errored"
if ls results/scored/gemma-4-31b/*.json >/dev/null 2>&1; then
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  bash scripts/pinchbench_run.sh gemma-4-31b >> "$L" 2>&1 || say "gemma pinchbench skipped/errored"
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  python3 import_pinchbench.py >> "$L" 2>&1
else
  say "!! gemma produced NO grid scores — flag."
fi
# judge gemma's writing/simpleqa + final rebuild
# [daemon-handles] python3 judge_writing.py  >> "$L" 2>&1
# [daemon-handles] python3 judge_simpleqa.py >> "$L" 2>&1
# [daemon-handles] python3 rescore_all.py    >> "$L" 2>&1
# [daemon-handles] python3 -m src.report.build_leaderboard >> "$L" 2>&1
cp -f leaderboard.html /home/ubuntu/.openclaw/workspace/leaderboard.html 2>/dev/null
say "GEMMA-LAST DONE — everything complete"
