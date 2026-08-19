#!/bin/bash
# Full-precision TerminalBench for the OTHER 4 frontier models (muse/qwen27/qwen35/gemma) via
# OpenRouter (non-GPU). qwen3.8's full Terminal is handled by qwen38_full_openrouter. Runs DEAD LAST
# on the non-GPU slot: gated until rec_pinch_full + the qwen3.8 wrapper + swe_full_queue are all gone,
# so the "1 non-GPU at a time" rule holds. Sequential (one model at a time), skip-guarded on the
# terminal results.json (>=80 tasks = done). Persistent parent so the child tb run survives.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
export PATH="$HOME/.local/bin:$PATH"
log(){ echo "[$(date +'%F %T')] $*" >> "$REPO/logs_full_terminal_queue.log"; }
done_tb(){ local p="results/terminalbench/$1/$1/results.json"; [ -f "$p" ] && \
  [ "$(python3 -c "import json;d=json.load(open('$p'));print(d.get('n_resolved',0)+d.get('n_unresolved',0))" 2>/dev/null||echo 0)" -ge 80 ]; }

# 1-non-GPU gate: wait until ALL other non-GPU work (pinch batch, qwen3.8 wrapper, other-4 SWE) is done.
while ps -eo args | grep -qE '[b]ash scripts/(rec_pinch_full|qwen38_full_openrouter|swe_full_queue)\.sh'; do sleep 120; done
log "full_terminal_queue up — other-4 full Terminal (muse->qwen27->qwen35->gemma), one at a time."
for k in muse qwen27 qwen35 gemma; do
  if done_tb "$k"; then log "$k full Terminal already done — skip"; continue; fi
  log "$k full Terminal (80) start"
  bash scripts/terminalbench_run.sh "$k" >>"$REPO/logs_tb_full_${k}.log" 2>&1 || log "  $k terminal non-zero"
  log "$k full Terminal done -> $(done_tb "$k" && echo complete || echo partial)"
done
log "full_terminal_queue COMPLETE."
