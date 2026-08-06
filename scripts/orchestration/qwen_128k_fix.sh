#!/bin/bash
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/qwen_128k_fix.log
say(){ echo "[qwenfix] $(date -u +%T) $*" >> "$L"; }
echo "=== qwen2.5-7b + qwen3-8b: 128K PinchBench fix (native-128K GGUFs) ===" > "$L"

# wait until stage2 is fully done (no stage2 script AND no grid/pinchbench inference active)
say "waiting for stage2 to finish (won't touch its GPU)"
while ps -eo cmd | grep -qE "bash /tmp/(stage2_newmodels|ornith_rerun|gptoss_medium)\.sh$" \
   || pgrep -f "run_benchmark.py --models" >/dev/null \
   || pgrep -f "benchmark.py --model openai/edge-" >/dev/null; do sleep 300; done
say "GPU free -> running qwen 128K pinchbench fixes"

for M in qwen2.5-7b-instruct qwen3-8b qwen3.5-9b; do   # glm-4-9b skipped (tool-parse fix too shaky)
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  rm -rf "models/$M" 2>/dev/null   # ensure the NEW 128K gguf gets pulled fresh
  # qwen3.5-9b was only 7/15 on the grid — fill the 8 missing benches FIRST (same GGUF just
  # pulled, standard grid context, no_think comes from models.yaml) so its weighted avg is
  # complete AND its PinchBench 6th-best/top-10 gate is decided on real data, not a partial set.
  if [ "$M" = "qwen3.5-9b" ]; then
    say "qwen3.5-9b grid fill (8 missing): aime2026 zebralogic gpqa_diamond babilong ruler writing bfcl simpleqa"
    python3 run_benchmark.py --models qwen3.5-9b --benchmarks aime2026 zebralogic gpqa_diamond babilong ruler writing bfcl simpleqa >> "$L" 2>&1 || say "qwen3.5-9b grid errored"
    # [daemon-handles] python3 judge_writing.py  >> "$L" 2>&1
    # [daemon-handles] python3 judge_simpleqa.py >> "$L" 2>&1
    # [daemon-handles] python3 rescore_all.py    >> "$L" 2>&1
    pkill -f 'llama-server' 2>/dev/null; sleep 8   # free port 8081 for the pinch server (solo-GPU)
    say "qwen3.5-9b grid fill done -> proceeding to PinchBench"
  fi
  say "launching $M PinchBench @128K"
  bash scripts/pinchbench_run.sh "$M" >> "$L" 2>&1 &
  PBPID=$!
  # clamp-guard: verify the server actually loaded 128K this time
  NCTX=""
  for i in $(seq 1 30); do
    sleep 10
    NCTX=$(curl -s http://127.0.0.1:8081/props 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('default_generation_settings',{}).get('n_ctx'))" 2>/dev/null)
    [ -n "$NCTX" ] && [ "$NCTX" != "None" ] && break
  done
  say "$M live n_ctx=$NCTX (want 131072)"
  if [ -z "$NCTX" ] || [ "$NCTX" = "None" ] || [ "$NCTX" -lt 100000 ] 2>/dev/null; then
    say "!! $M STILL clamped to $NCTX — native-128K GGUF didn't take either. Killing + FLAGGING (needs manual look)."
    kill "$PBPID" 2>/dev/null; pkill -f 'llama-server' 2>/dev/null; sleep 8
    continue
  fi
  say "$M n_ctx=131072 OK ✓ -> running full PinchBench"
  wait "$PBPID"
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  python3 import_pinchbench.py >> "$L" 2>&1
  # [daemon-handles] python3 -m src.report.build_leaderboard >> "$L" 2>&1
  rm -rf "models/$M" 2>/dev/null   # free disk for the next
done
# exaone-4.5-33b PinchBench — was gate-SKIPPED on a PARTIAL avg (54.3, writing unjudged); it's now
# 59.9 with writing in, so it clears the top-10 gate. no_think is auto-applied from config now.
pkill -f 'llama-server' 2>/dev/null; sleep 8
rm -rf models/exaone-4.5-33b 2>/dev/null
say "exaone-4.5-33b PinchBench @128K (FORCE — shujun wants it; no_think auto)"
FORCE_PINCH=1 bash scripts/pinchbench_run.sh exaone-4.5-33b >> "$L" 2>&1 || say "exaone pinch skipped/errored"
pkill -f 'llama-server' 2>/dev/null; sleep 8
python3 import_pinchbench.py >> "$L" 2>&1
# [daemon-handles] python3 -m src.report.build_leaderboard >> "$L" 2>&1
cp -f leaderboard.html /home/ubuntu/.openclaw/workspace/leaderboard.html 2>/dev/null
rm -rf models/exaone-4.5-33b 2>/dev/null

say "QWEN 128K FIX DONE"
