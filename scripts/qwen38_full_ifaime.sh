#!/bin/bash
# DEAD-LAST: Qwen3.8-full IFBench + AIME (fp8/vLLM). Waits until ALL other work is done
# (q4_agentic_queue exited + .QWEN38_DONE set), then serves vLLM fp8 and runs the 2 benchmarks.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
VLLM=/home/aliixh/vllm-env/bin/vllm
FP8=$REPO/models/qwen3.8-27b-fp8
PORT=8081
log(){ echo "[$(date +'%F %T')] $*"; }
free_gpu(){ for p in $(pgrep -f 'vllm|llama-server'); do kill -9 "$p" 2>/dev/null; done; }

log "qwen38_full_ifaime: waiting for ALL other work to finish (this is the very end)..."
until [ -f .QWEN38_DONE ] && ! pgrep -f 'q4_agentic_queue|qwen38_q4_seq|qwen38_full_seq' >/dev/null; do sleep 300; done
if [ -f results/scored/qwen3.8-27b-full/ifbench.json ] && [ -f results/scored/qwen3.8-27b-full/aime2026.json ]; then
  log "already done — exiting"; exit 0; fi

log "all clear. Serving Qwen3.8 fp8 via vLLM for IFBench + AIME."
free_gpu; sleep 3
"$VLLM" serve "$FP8" --served-model-name edge-qwen38-full --host 127.0.0.1 --port $PORT \
  --quantization fp8 --max-model-len 98304 --reasoning-parser qwen3 >/tmp/vllm_ifaime.log 2>&1 &
VP=$!; trap "kill $VP 2>/dev/null; free_gpu" EXIT
for i in $(seq 1 240); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; sleep 3; done
export IFBENCH_DIR=/home/aliixh/IFBench
log "running IFBench + AIME (rec: temp1.0/top_p0.95/top_k20/presence0.0, thinking ON, max_tok 81920)"
python3 run_benchmark.py --models-config configs/models_qwen38_full_ifaime.yaml \
  --models qwen3.8-27b-full --benchmarks ifbench aime2026 >>"$REPO/logs_ifaime_qwen38_full.log" 2>&1 || log "  errored"
free_gpu
log "qwen38_full_ifaime COMPLETE -> $(python3 -c "import json;print('IFb',round(json.load(open('results/scored/qwen3.8-27b-full/ifbench.json'))['score']*100,1),'AIME',round(json.load(open('results/scored/qwen3.8-27b-full/aime2026.json'))['score']*100,1))" 2>/dev/null||echo '?')"
