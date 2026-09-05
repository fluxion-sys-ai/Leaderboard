#!/bin/bash
# Deferred Claude-reference Docker benchmarks (Terminal-12 + SWE-8), run AFTER the GPU sweep frees the
# box. Terminal/SWE spawn local Docker containers that contend with gemma/muse's llama-server RAM, so
# they MUST wait until the Q4 terminal sweep is done. Self-gating + budget-floored + once-only.
# Cron-driven (reboot durable). Gates: gemma+muse full80 complete, GPU free, credit>floor, not-done.
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO" || exit 1
LOG="$REPO/logs_claude_docker.log"
DONEFLAG="$REPO/.claude_docker_done"
FLOOR=8.0   # keep >= $8 OpenRouter credit in reserve; abort a phase that would dip below
exec >>"$LOG" 2>&1

[ -f "$DONEFLAG" ] && exit 0

# --- gate 1: gemma + muse Q4 full80 complete (79 tasks each) ---
for k in gemma muse; do
  f="$REPO/results/terminalbench_q4/${k}_full80/results.json"
  n=$([ -f "$f" ] && python3 -c "import json;d=json.load(open('$f'));print(d.get('n_resolved',0)+d.get('n_unresolved',0))" 2>/dev/null || echo 0)
  [ "${n:-0}" -ge 79 ] || { echo "[$(date -u)] defer: $k Q4 full80 not done ($n/79)"; exit 0; }
done
# --- gate 2: GPU free (no llama-server holding it) ---
pgrep -x llama-server >/dev/null && { echo "[$(date -u)] defer: GPU still busy (llama-server up)"; exit 0; }
# --- gate 3: credit above floor ---
cred=$(curl -s https://openrouter.ai/api/v1/credits -H "Authorization: Bearer $(cat "$REPO/.openrouter_key")" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin)['data'];print(f\"{d['total_credits']-d['total_usage']:.2f}\")" 2>/dev/null || echo 0)
awk "BEGIN{exit !($cred > $FLOOR)}" || { echo "[$(date -u)] abort: credit \$$cred <= floor \$$FLOOR"; touch "$DONEFLAG"; exit 0; }

echo "=== [$(date -u)] Claude Docker benchmarks START (gemma+muse done, GPU free, credit \$$cred) ==="

# --- Terminal-12 (stratified sample) ---
echo "[$(date -u)] Claude Terminal-12"
TB_OUT="$REPO/results/terminalbench/claude_ref" TB_RUNID="clauderef" TB_MULT=1.0 \
  TB_SAMPLE_FILE="$REPO/configs/claude_ref_terminal_sample.txt" \
  bash scripts/terminalbench_run.sh claude || echo "[Terminal-12] non-zero"

# --- re-check credit before the expensive SWE phase ---
cred=$(curl -s https://openrouter.ai/api/v1/credits -H "Authorization: Bearer $(cat "$REPO/.openrouter_key")" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin)['data'];print(f\"{d['total_credits']-d['total_usage']:.2f}\")" 2>/dev/null || echo 0)
if awk "BEGIN{exit !($cred > $FLOOR)}"; then
  echo "[$(date -u)] Claude SWE-8 (credit \$$cred)"
  IDS=$(paste -sd, "$REPO/configs/claude_ref_swe_sample.txt")
  bash scripts/swe_agentless_run.sh claude --ids "$IDS" --tag ref >>"$LOG" 2>&1 || echo "[SWE-8] agentless non-zero"
  SWE_OR=1 bash scripts/swe_full_select.sh claude >>"$LOG" 2>&1 || echo "[SWE-8] select non-zero (kept old)"
else
  echo "[$(date -u)] SKIP SWE-8: credit \$$cred <= floor \$$FLOOR (Terminal done, budget spent)"
fi

# --- score/import + rebuild board ---
python3 import_pinchbench.py >>"$LOG" 2>&1 || true
timeout 180 python3 -m src.report.build_leaderboard >/dev/null 2>&1 && cp leaderboard.html docs/index.html
touch "$DONEFLAG"
echo "=== [$(date -u)] Claude Docker benchmarks DONE ==="
