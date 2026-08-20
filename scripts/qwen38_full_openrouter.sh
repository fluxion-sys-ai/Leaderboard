#!/bin/bash
# Qwen3.8-27B FULL-precision — ALL cells via OpenRouter (qwen/qwen3.8-27b, fp8). NO self-hosted vLLM.
# Order: Pinch (fast) -> IFBench+AIME -> SWE-Lite (20-sample) -> Terminal (full 80). Every step is
# skip-guarded on its scored output, so this is fully resumable (IF/AIME also caches per-task).
# Persistent parent so child run_benchmark/agentless/tb procs survive the tool-call boundary.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO"
export IFBENCH_DIR=/home/aliixh/IFBench
FN=qwen3.8-27b-full
log(){ echo "[$(date +'%F %T')] $*" >> "$REPO/logs_qwen38_full_or.log"; }
log "qwen38_full_openrouter up — Pinch/Terminal/SWE via OpenRouter fp8."
# PRIORITIZED (user standing order: ALWAYS prioritize qwen3.8). This runs the qwen3.8-full pipeline
# FIRST on the non-GPU slot; the other-4 SWE queue (swe_full_queue) waits until our SWE cell is scored.
# No gate here — start immediately.
log "qwen3.8-full PRIORITIZED — starting immediately (other-4 SWE waits for us)."

# rec_pinch_full.sh owns ALL full-precision PinchBench (rec/default thinking-ON). Wait for it so we
# never double-run qwen3.8 pinch; once it's done, our Pinch step below is skip-guarded (cell exists).
while ps -eo args | grep -q '[b]ash scripts/rec_pinch_full.sh'; do sleep 60; done

# 1) PinchBench at REC/DEFAULT (thinking ON) — normally already done by rec_pinch_full; this is a
#    skip-guarded fallback so the wrapper is self-sufficient if rec_pinch_full never ran.
if [ ! -f "results/scored/$FN/pinchbench.json" ]; then
  log "Pinch start"
  bash scripts/pinchbench_full_run.sh qwen38 >>"$REPO/logs_pb_full_qwen38.log" 2>&1 || log "pinch non-zero"
  python3 - <<'PY' 2>/dev/null || log "pinch import failed"
import json, glob, os
best=None
for f in sorted(glob.glob('/home/aliixh/pinchbench-skill/results/*.json'), key=os.path.getmtime, reverse=True):
    try: d=json.load(open(f))
    except Exception: continue
    m=(d.get('model') or '').lower().replace('/','-').replace('.','-')
    if 'qwen3-8-27b' not in m: continue          # ONLY Qwen3.8-27B (won't match 3.6-27b)
    cs=d.get('category_scores') or {}; tm=sum(c['max_score'] for c in cs.values())
    if tm>=115:
        os.makedirs('results/scored/qwen3.8-27b-full', exist_ok=True)
        json.dump({'score':round(sum(c['score'] for c in cs.values())/tm,4),'metric':'pinchbench_pct','benchmark':'pinchbench'},
                  open('results/scored/qwen3.8-27b-full/pinchbench.json','w')); print('imported'); break
PY
  log "Pinch done -> $([ -f results/scored/$FN/pinchbench.json ]&&echo scored||echo none)"
fi

# (IFBench + AIME intentionally SKIPPED for qwen3.8-full per user — only Pinch, SWE, Terminal.)

# 2) TerminalBench (24-task stratified sample, terminus-2 via OpenRouter) — order per user: Pinch ->
# Terminal -> SWE. Completeness check (>= sample size), NOT mere existence — a partial results.json
# (e.g. the 2/80 jumper) must NOT count as done, or terminal gets skipped. terminal-bench resumes
# completed trials on re-run.
TB_EXPECT=$(grep -cE "[^[:space:]]" "$REPO/configs/terminal_sample.txt" 2>/dev/null || echo 80); [ "${TB_EXPECT:-0}" -gt 0 ] || TB_EXPECT=80
TBF="results/terminalbench/qwen38/qwen38/results.json"
TB_DONE=$([ -f "$TBF" ] && python3 -c "import json,sys;d=json.load(open('$TBF'));print(1 if (d.get('n_resolved',0)+d.get('n_unresolved',0))>=$TB_EXPECT else 0)" 2>/dev/null || echo 0)
if [ "$TB_DONE" != "1" ]; then
  export PATH="$HOME/.local/bin:$PATH"
  log "Terminal start (stratified sample, $TB_EXPECT tasks)"
  bash scripts/terminalbench_run.sh qwen38 >>"$REPO/logs_tb_full_qwen38.log" 2>&1 || log "terminal non-zero"
  log "Terminal done"
fi

# 3) SWE-Lite on the 20-sample (OpenRouter fp8 — no SWE_API_BASE => OpenRouter)
if [ ! -f "results/scored/$FN/swebench_lite.json" ]; then
  log "SWE start (20-sample)"
  bash scripts/swe_agentless_run.sh qwen38 --subset strat50 >>"$REPO/logs_swe_full_qwen38.log" 2>&1 || log "SWE non-zero"
  log "SWE done -> $([ -f results/scored/$FN/swebench_lite.json ]&&echo scored||echo none)"
fi
log "qwen38_full_openrouter COMPLETE."
