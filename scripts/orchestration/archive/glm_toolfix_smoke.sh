#!/bin/bash
# Fix attempt for GLM's 116-task PinchBench (5.7 = live agent can't parse GLM's tool calls).
# STEP 1: 3-task smoke with --chat-template chatglm4 under a throwaway tag.
# STEP 2: if the smoke clearly beats the 5.7 baseline (tools actually executed), auto-run
#         the FULL 116-task re-run with that template, re-import, rebuild. Else: footnote GLM.
set -u
cd /home/aliixh/edge-intelligence-benchmark
PB=/home/aliixh/pinchbench-skill; PORT=8081; LOG=/tmp/glm_toolfix_smoke.log
export OPENROUTER_API_KEY="$(cat .openrouter_key)"; export OPENAI_API_KEY=sk-local
echo "[glm-fix] waiting for batched + GPU free $(date -u +%T)" > $LOG
while pgrep -f 'batched_fix_run.sh' >/dev/null || pgrep -f 'llama-b9892/llama-server' >/dev/null; do sleep 120; done
pkill -f 'llama-server' 2>/dev/null; sleep 6

# --- STEP 1: smoke with chatglm4 template (throwaway tag) ---
echo "[glm-fix] STEP1 smoke: glm 3 tasks, --chat-template chatglm4 $(date -u +%T)" >> $LOG
GGUF=$(python3 -c "
import sys,yaml; sys.path.insert(0,'.')
from src.models_fetch import ensure_gguf
m=next(x for x in yaml.safe_load(open('configs/models.yaml'))['models'] if x['name']=='glm-4-9b-0414')
print(ensure_gguf(m['name'],m['gguf']))")
/home/aliixh/llama.cpp/llama-b9892/llama-server -m "$GGUF" -c 32768 --parallel 1 -ngl 999 \
  --chat-template chatglm4 --host 127.0.0.1 --port $PORT --no-webui >/tmp/glm_B_llama.log 2>&1 &
LP=$!
for i in $(seq 1 120); do curl -sf http://127.0.0.1:$PORT/health >/dev/null 2>&1 && break; sleep 2; done
( cd "$PB" && uv run scripts/benchmark.py --model openai/edge-glm-toolfix \
  --base-url http://127.0.0.1:$PORT/v1 --judge openrouter/deepseek/deepseek-chat-v3.1 \
  --suite task_calendar,task_stock,task_blog >> $LOG 2>&1 )
kill $LP 2>/dev/null; sleep 4; pkill -f 'llama-server' 2>/dev/null; sleep 4

SMOKE=$(python3 -c "
import json,glob,os
fs=sorted(glob.glob('$PB/results/*glm-toolfix*.json'),key=os.path.getmtime)
if not fs: print('0'); exit()
d=json.load(open(fs[-1])); cs=d.get('category_scores',{})
s=sum(v['score'] for v in cs.values()); m=sum(v['max_score'] for v in cs.values())
print(round(100*s/m,1) if m else 0)
" 2>/dev/null)
echo "[glm-fix] smoke score = ${SMOKE}% (baseline 5.7%)" >> $LOG

# --- STEP 2: decide ---
GO=$(python3 -c "print('yes' if float('${SMOKE:-0}') >= 20 else 'no')" 2>/dev/null)
if [ "$GO" = "yes" ]; then
  echo "[glm-fix] smoke PASSED -> full 116-task re-run with chatglm4 $(date -u +%T)" >> $LOG
  mkdir -p $PB/results/_pre_glmfix
  mv -f $PB/results/*edge-glm-4-9b-0414*.json $PB/results/_pre_glmfix/ 2>/dev/null
  CHAT_TEMPLATE=chatglm4 bash scripts/pinchbench_run.sh glm-4-9b-0414 >> $LOG 2>&1
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  python3 import_pinchbench.py >> $LOG 2>&1
  python3 -m src.report.build_leaderboard >> $LOG 2>&1
  cp -f leaderboard.html /home/aliixh/edge_leaderboard.html 2>/dev/null
  NEW=$(python3 -c "import json;print(round(json.load(open('results/scored/glm-4-9b-0414/pinchbench.json'))['score']*100,1))" 2>/dev/null)
  echo "[glm-fix] DONE — glm PinchBench 5.7 -> ${NEW} $(date -u +%T)" >> $LOG
else
  echo "[glm-fix] smoke did NOT beat baseline (${SMOKE}%) — chatglm4 template doesn't fix parsing. Keep footnote. $(date -u +%T)" >> $LOG
fi
