#!/bin/bash
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/chain_redos.log
say(){ echo "[chain] $(date -u +%T) $*" >> "$L"; }
echo "=== context-fix chain (with clamp guard) ===" > "$L"

# 0) wait for the in-flight 27B @128K PinchBench to finish (solo-GPU rule)
say "waiting for 27B PinchBench to finish"
while pgrep -f "benchmark.py --model openai/edge-qwen3.6-27b" >/dev/null; do sleep 60; done
say "27B done -> import + build"
python3 import_pinchbench.py >> "$L" 2>&1
python3 -m src.report.build_leaderboard >> "$L" 2>&1

# 1) redo context-bound models. GUARD: if the live server n_ctx isn't ~128K
#    (YaRN clamp to 32K), KILL it immediately instead of wasting a ~2h thrash run.
for M in qwen3.5-35b-a3b qwen2.5-7b-instruct qwen3-8b; do
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  say "launching $M PinchBench (corrected context)"
  bash scripts/pinchbench_run.sh "$M" >> "$L" 2>&1 &
  PBPID=$!
  # poll for server up (max ~4min for big model load), then read actual n_ctx
  NCTX=""
  for i in $(seq 1 24); do
    sleep 10
    NCTX=$(curl -s http://127.0.0.1:8081/props 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('default_generation_settings',{}).get('n_ctx') or d.get('n_ctx'))" 2>/dev/null)
    [ -n "$NCTX" ] && [ "$NCTX" != "None" ] && break
  done
  say "$M live server n_ctx=$NCTX"
  if [ -z "$NCTX" ] || [ "$NCTX" = "None" ] || [ "$NCTX" -lt 100000 ] 2>/dev/null; then
    say "!! $M n_ctx=$NCTX < 100000 => CLAMP/LOAD FAIL. Killing to avoid a wasted thrash run. SKIPPED — needs manual YaRN fix."
    kill "$PBPID" 2>/dev/null
    pkill -f 'llama-server' 2>/dev/null; sleep 8
    continue
  fi
  say "$M n_ctx OK (>=100k) -> letting it run"
  wait $PBPID
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  say "$M done -> import + build"
  python3 import_pinchbench.py >> "$L" 2>&1
  python3 -m src.report.build_leaderboard >> "$L" 2>&1
done

# 2) NEW PinchBench for models that only had BFCL (ornith, phi). No clamp-guard: they run
#    at their native ctx (llama.cpp caps if <128K, no error) — skipping would be wrong.
for M in ornith-1.0-9b phi-4-mini-instruct; do
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  say "launching $M PinchBench (new — first agentic run)"
  bash scripts/pinchbench_run.sh "$M" >> "$L" 2>&1 || say "$M pinchbench errored"
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  say "$M done -> import + build"
  python3 import_pinchbench.py >> "$L" 2>&1
  python3 -m src.report.build_leaderboard >> "$L" 2>&1
done
cp -f leaderboard.html /home/ubuntu/edge_leaderboard.html 2>/dev/null
say "ALL REDOS + NEW PINCHBENCH (ornith, phi) DONE"
