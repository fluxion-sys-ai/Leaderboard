#!/bin/bash
# Qwen3.8-27B FULL-precision (fp8, self-hosted via vLLM — not on OpenRouter). Serves the fp8
# weights on :8081 (OpenAI-compatible) and runs PinchBench -> Terminal -> SWE-Lite against it,
# reusing the same edgelocal(:8081) plumbing as the Q4 path. Each phase SMOKE-GATED (this is a
# new path). Thinking: Pinch = no_think (rec for agentic pinch), Terminal/SWE = thinking ON.
# NOTE: vLLM lifecycle + Qwen3 reasoning-parser; verify on first run.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
VLLM=/home/aliixh/vllm-env/bin/vllm
FP8=$REPO/models/qwen3.8-27b-fp8
PORT=8081
FN=qwen3.8-27b-full
log(){ echo "[$(date +'%F %T')] $*"; }
free_gpu(){ for p in $(pgrep -f 'vllm|llama-server'); do kill -9 "$p" 2>/dev/null; done; }
# CRITICAL: .QWEN38_DONE is the gate that unblocks the other-4 Q4 queue + the dead-last IF/AIME
# run. It MUST be set on ANY exit (vLLM-serve failure, crash, error) — otherwise a single failure
# here permanently deadlocks every downstream queue (they wait on it with no timeout). Setting it
# on early-exit means "qwen38 priority phase is over"; missing cells just render as pending.
trap ': > "$REPO/.QWEN38_DONE"' EXIT

serve_vllm(){  # $1 = extra args (e.g. thinking default)
  free_gpu; sleep 3
  "$VLLM" serve "$FP8" --served-model-name edge-qwen38-full \
    --host 127.0.0.1 --port $PORT --quantization fp8 --max-model-len 98304 \
    --reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser hermes \
    >/tmp/vllm_qwen38.log 2>&1 &
  echo $! > /tmp/vllm_qwen38.pid
  for i in $(seq 1 240); do curl -sf --max-time 8 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && return 0; sleep 3; done
  log "vLLM failed to come up in 12min — see /tmp/vllm_qwen38.log"; return 1
}

log "===== Qwen3.8 FULL (fp8/vLLM) PRIORITY: Pinch -> Terminal -> SWE ====="
if ! serve_vllm; then log "ABORT: vLLM not serving"; exit 1; fi
log "vLLM up (fp8, :$PORT). Qwen3.8 full-precision served as edge-qwen38-full."
export OPENAI_API_BASE="http://127.0.0.1:$PORT/v1" OPENAI_API_KEY="sk-local"
export OPENROUTER_API_KEY="$(cat "$REPO/.openrouter_key")"   # deepseek judge for pinch

# --- 1/3 PinchBench (no_think + rec sampling FORCED via the vllmfull provider params) ---
if [ ! -f "results/scored/$FN/pinchbench.json" ]; then
  cd /home/aliixh/pinchbench-skill
  # SMOKE 3 tasks: if all-zero, vLLM no_think isn't taking effect (thinking-ON zeroes pinch) -> flag+skip
  S3=$(head -3 "$REPO/configs/pinchbench_tasks.txt" | paste -sd,)
  log "1/3 Pinch full-fp8 SMOKE (vllmfull/qwen38, no_think forced)"
  uv run scripts/benchmark.py --model vllmfull/qwen38 --thinking off \
    --judge openrouter/deepseek/deepseek-chat-v3.1 --suite "$S3" >/tmp/pb_full_qwen38_smoke.log 2>&1 || true
  cd "$REPO"
  SNZ=$(grep -E 'Task task.*: [0-9.]+/1.0' /tmp/pb_full_qwen38_smoke.log 2>/dev/null | grep -cvE ': 0.0/'); SNZ=${SNZ:-0}
  if [ "${SNZ:-0}" -lt 1 ]; then
    log "  Pinch full-fp8 SMOKE all-zero -> vLLM no_think likely not applied. SKIPPING full (needs a look)."
  else
  cd /home/aliixh/pinchbench-skill
  SUITE=$(paste -sd, "$REPO/configs/pinchbench_tasks.txt")
  log "  Pinch full-fp8 FULL (vllmfull/qwen38)"
  uv run scripts/benchmark.py --model vllmfull/qwen38 --thinking off \
    --judge openrouter/deepseek/deepseek-chat-v3.1 --suite "$SUITE" >>"$REPO/logs_pb_full_qwen38.log" 2>&1 || log "  pinch errored"
  cd "$REPO"
  python3 - <<'PY' 2>/dev/null || true
import json,glob,os
for f in sorted(glob.glob('/home/aliixh/pinchbench-skill/results/*.json'),key=os.path.getmtime,reverse=True):
    d=json.load(open(f))
    if 'vllmfull-qwen38' in (d.get('model') or ''):   # ONLY the full-fp8 transcript — not Q4/other 'qwen38' runs
        cs=d.get('category_scores') or {};tm=sum(c['max_score'] for c in cs.values())
        if tm>=115:
            os.makedirs('results/scored/qwen3.8-27b-full',exist_ok=True)
            json.dump({'score':round(sum(c['score'] for c in cs.values())/tm,4),'metric':'pinchbench_pct','benchmark':'pinchbench'},open('results/scored/qwen3.8-27b-full/pinchbench.json','w'));print('imported');break
PY
  fi
fi

# --- 2/3 SWE-Lite (thinking ON via Agentless extra_body) ---
if [ ! -f "results/scored/$FN/swebench_lite.json" ]; then
  log "2/3 SWE full-fp8 (strat50)"
  SWE_API_BASE="http://127.0.0.1:$PORT/v1" SWE_API_KEY="sk-local" SWE_PRECISION="full" \
    bash scripts/swe_agentless_run.sh qwen38 --subset strat50 >>"$REPO/logs_swe_full_qwen38.log" 2>&1 || log "  swe errored"
fi

# --- 3/3 Terminal (LAST — the slow one; thinking ON via TB_MODEL_PARAMS) ---
if [ ! -f "results/terminalbench/qwen38full/qwen38full/results.json" ]; then
  export PATH="$HOME/.local/bin:$PATH"
  export TB_MODEL_PARAMS='{"top_p":0.95,"extra_body":{"top_k":20,"min_p":0,"presence_penalty":0.0,"chat_template_kwargs":{"enable_thinking":true}}}'
  OUT="$REPO/results/terminalbench/qwen38full"; mkdir -p "$OUT"
  log "3/3 Terminal full-fp8"
  tb run --dataset terminal-bench-core==0.1.1 --agent terminus-2 --agent-kwarg temperature=1.0 \
    --model openai/edge-qwen38-full --output-path "$OUT" --run-id qwen38full \
    --n-concurrent 2 --global-agent-timeout-sec 2400 --cleanup >>"$REPO/logs_tb_full_qwen38.log" 2>&1 || log "  terminal errored"
fi

free_gpu
: > "$REPO/.QWEN38_DONE"
log "===== Qwen3.8 FULL sequence COMPLETE. .QWEN38_DONE set (main queue may proceed). ====="
