#!/bin/bash
# Concurrent non-GPU worker: while the GPU pipeline runs, keep judging any NEW+complete
# writing/simpleqa and rebuilding the dashboard — in PARALLEL (API/CPU only, zero GPU contention),
# so judge sweeps no longer stall the GPU queue. Both judges have skip-guards → no drift, no dup work.
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/judge_daemon.log
say(){ echo "[judge-daemon] $(date -u +%T) $*" >> "$L"; }
echo "=== concurrent judge + rebuild daemon (no GPU) ===" > "$L"
pipeline_alive(){ ps -eo cmd | grep -qE "bash /tmp/(stage2_newmodels|ornith_rerun|gptoss_medium|qwen_128k_fix|gemma_last|gemma_e4b|lfm_tess)\.sh$" \
  || pgrep -f "run_benchmark.py --models" >/dev/null || pgrep -f "benchmark.py --model openai/edge-" >/dev/null; }
while pipeline_alive; do
  say "sweep"
  python3 judge_writing.py  >> "$L" 2>&1
  python3 judge_simpleqa.py >> "$L" 2>&1
  python3 -m src.report.build_leaderboard >> "$L" 2>&1
  cp -f leaderboard.html docs/index.html 2>/dev/null
  cp -f leaderboard.html /home/ubuntu/.openclaw/workspace/leaderboard.html 2>/dev/null
  sleep 180
done
# final pass once the pipeline is fully done
python3 judge_writing.py >> "$L" 2>&1; python3 judge_simpleqa.py >> "$L" 2>&1
python3 rescore_all.py    >> "$L" 2>&1
python3 -m src.report.build_leaderboard >> "$L" 2>&1
cp -f leaderboard.html docs/index.html 2>/dev/null
cp -f leaderboard.html /home/ubuntu/.openclaw/workspace/leaderboard.html 2>/dev/null
say "DAEMON DONE (pipeline finished)"
