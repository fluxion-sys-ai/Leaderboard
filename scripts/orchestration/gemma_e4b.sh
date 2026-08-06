#!/bin/bash
# gemma-4-e4b grid RERUN — its grid ran before no_think was set, so ~30% of outputs were empty
# (thinking dumped -> stripped -> 0). no_think:true is now in config, so a clean re-run un-fakes it.
# Runs DEAD LAST — waits for every other job. Grid only (4B, avg ~49 -> pinch gate skips it anyway).
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/gemma_e4b.log
say(){ echo "[gemma-e4b] $(date -u +%T) $*" >> "$L"; }
echo "=== gemma-4-e4b grid rerun (no_think fix) — dead last ===" > "$L"
BENCH="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl simpleqa"

# wait for EVERYTHING else to finish
say "waiting for ornith + gptoss_medium + qwen-fix + gemma-31b to all finish"
while ps -eo cmd | grep -qE "bash /tmp/(ornith_rerun|gptoss_medium|qwen_128k_fix|gemma_last)\.sh$" \
   || pgrep -f "run_benchmark.py --models" >/dev/null \
   || pgrep -f "benchmark.py --model openai/edge-" >/dev/null; do sleep 300; done
say "everything else done -> gemma-4-e4b grid rerun"

# confirm no_think is actually set (else the rerun would just reproduce the contamination)
if ! python3 -c "import yaml,sys;m=[x for x in yaml.safe_load(open('configs/models.yaml'))['models'] if x['name']=='gemma-4-e4b'];sys.exit(0 if (m and m[0].get('no_think')) else 1)" 2>/dev/null; then
  say "!! gemma-4-e4b has no no_think in config — ABORT (rerun would be pointless)"; exit 1
fi

pkill -f 'llama-server' 2>/dev/null; sleep 8
rm -rf results/scored/gemma-4-e4b results/raw/gemma-4-e4b   # clear the contaminated grid
say "grid (no_think on)"
python3 run_benchmark.py --models gemma-4-e4b --benchmarks $BENCH >> "$L" 2>&1 || say "gemma-4-e4b grid errored"
if ls results/scored/gemma-4-e4b/*.json >/dev/null 2>&1; then
  :   # judging/rescoring/rebuild handled concurrently by the judge daemon
else
  say "!! gemma-4-e4b produced NO grid scores — flag."
fi
# [daemon-handles] python3 -m src.report.build_leaderboard >> "$L" 2>&1
cp -f leaderboard.html /home/ubuntu/.openclaw/workspace/leaderboard.html 2>/dev/null
rm -rf models/gemma-4-e4b 2>/dev/null
say "GEMMA-4-E4B RERUN DONE — everything complete"
