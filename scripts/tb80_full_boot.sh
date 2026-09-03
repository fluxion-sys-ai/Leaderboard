#!/bin/bash
# Boot wrapper for the full-precision TerminalBench full-80 sweep, launched by systemd on reboot/crash.
# Idempotent: if all 5 models already have a complete full-80 (79 tasks merged), it exits 0 (nothing to
# do) so a post-completion reboot doesn't needlessly re-run. Otherwise it (re)launches the sweep, which
# resumes via merge (base-24 is always preserved; the remaining-55 re-runs if it was mid-flight).
set -uo pipefail
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
cd "$REPO" || exit 1

# already running? (don't double-launch)
if pgrep -f "tb80_full_queue.sh" >/dev/null 2>&1; then
  echo "[boot] full sweep already running -> nothing to do"; exit 0
fi

# all 5 full80 complete? (79 = 24 + 55, play-zork excluded)
done=0
for k in qwen38 qwen27 qwen35 gemma muse; do
  f="$REPO/results/terminalbench/${k}_full80/results.json"
  n=$([ -f "$f" ] && python3 -c "import json;d=json.load(open('$f'));print(d.get('n_resolved',0)+d.get('n_unresolved',0))" 2>/dev/null || echo 0)
  [ "${n:-0}" -ge 79 ] && done=$((done+1))
done
if [ "$done" -eq 5 ]; then echo "[boot] all 5 full80 complete -> nothing to do"; exit 0; fi

echo "[boot] launching full-precision full-80 sweep ($done/5 complete)"
exec bash "$REPO/scripts/tb80_full_queue.sh"
