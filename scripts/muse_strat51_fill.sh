#!/bin/bash
# Safety fill for muse's strat-51 SWE: after the main strat-51 run finishes, if repair coverage is
# still low (muse's provider is finicky), do a 2nd pass (--skip_existing retries only the missing),
# then re-run repro-40 + eval. Ensures muse reaches ~full strat-51 coverage.
set -uo pipefail
cd /home/aliixh/.openclaw/workspace/edge-intelligence-benchmark || exit 1
LOG=logs_muse_strat51_fill.log
echo "=== muse strat-51 fill: waiting for main run $(date -u) ===" > "$LOG"
while ps -eo args | grep -q "[s]we_agentless_run.sh muse"; do sleep 120; done
cov(){ python3 -c "import glob,json;ids=set();[ids.add(json.loads(l)['instance_id']) for f in glob.glob('results/swe_agentless/muse-orf/repair/output_0_processed.jsonl') for l in open(f)];print(len(ids))" 2>/dev/null||echo 0; }
c=$(cov); echo "coverage after main run: $c/51" >> "$LOG"
for pass in 1 2; do
  [ "$c" -ge 48 ] && { echo "coverage ok ($c) — no fill needed" >> "$LOG"; break; }
  echo "=== fill pass $pass (coverage $c) $(date -u) ===" >> "$LOG"
  bash scripts/swe_agentless_run.sh muse --tag orf --subset strat51 >> "$LOG" 2>&1 || true
  c=$(cov); echo "coverage after pass $pass: $c/51" >> "$LOG"
done
echo "=== muse strat-51 fill: repro-40 + eval on final coverage $(date -u) ===" >> "$LOG"
SWE_OR=1 bash scripts/swe_full_select.sh muse >> "$LOG" 2>&1 || true
echo "=== muse strat-51 fill DONE (final coverage $(cov)/51) $(date -u) ===" >> "$LOG"
