#!/bin/bash
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
log(){ echo "[$(date +'%F %T')] $*"; }
until ! pgrep -f qwen38_q4_seq >/dev/null; do sleep 120; done
log "qwen38 Q4 seq finished -> launching full-fp8 (vLLM) seq"
bash scripts/qwen38_full_seq.sh
log "qwen38 chain COMPLETE (both precisions done)"
