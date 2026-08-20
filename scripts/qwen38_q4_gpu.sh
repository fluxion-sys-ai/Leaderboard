#!/bin/bash
# qwen3.8-Q4 on the GPU (llama.cpp): finish Terminal (80) then SWE-Lite (20-sample). Pinch already
# scored (35.9%). Prioritized per user. Runs on the GPU slot; qwen3.8-full is on OpenRouter (non-GPU).
# Persistent parent so the llama-server/tb/agentless children survive. Skip-guarded/resumable.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
export PATH="$HOME/.local/bin:$PATH"
FN=qwen3.8-27b-q4f
log(){ echo "[$(date +'%F %T')] $*" >> "$REPO/logs_qwen38_q4_gpu.log"; }
free_gpu(){
  for p in $(pgrep -f 'llama-server'); do kill -9 "$p" 2>/dev/null; done
  for p in $(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  sleep 2
}
log "qwen38_q4_gpu up — Terminal(80) then SWE(20) for qwen3.8-Q4."

# 1) TerminalBench Q4 (full 80)
TBF="results/terminalbench_q4/qwen38/qwen38/results.json"
# sample-aware completeness: expect the stratified sample size (24) when the sample file is present,
# else full-80. Prevents a wrapper restart from wastefully re-running an already-complete sample.
TB_EXPECT=$([ -s "$REPO/configs/terminal_sample.txt" ] && grep -c . "$REPO/configs/terminal_sample.txt" || echo 80)
DONE_T=$([ -f "$TBF" ] && python3 -c "import json;d=json.load(open('$TBF'));print(1 if (d.get('n_resolved',0)+d.get('n_unresolved',0))>=$TB_EXPECT else 0)" 2>/dev/null || echo 0)
if [ "$DONE_T" != "1" ]; then
  free_gpu
  log "Terminal Q4 qwen38 (80) start"
  bash scripts/terminalbench_q4_run.sh qwen38 >>"$REPO/logs_tb_q4_qwen38.log" 2>&1 || log "  terminal errored"
  log "Terminal Q4 qwen38 done"
fi

# 2) SWE-Lite Q4 (20-sample)
if [ ! -f "results/scored/$FN/swebench_lite.json" ]; then
  free_gpu
  log "SWE Q4 qwen38 (20-sample) start"
  bash scripts/swe_agentless_q4_run.sh qwen38 --subset strat50 >>"$REPO/logs_swe_q4_qwen38.log" 2>&1 || log "  swe errored"
  log "SWE Q4 qwen38 done -> $([ -f results/scored/$FN/swebench_lite.json ]&&echo scored||echo none)"
fi
free_gpu
log "qwen38_q4_gpu COMPLETE."
