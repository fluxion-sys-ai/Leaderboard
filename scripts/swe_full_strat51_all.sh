#!/bin/bash
# Full-precision SWE-bench Lite on the strat-51 sample (MATCH the Q4 denominator), all 5 models in
# PARALLEL on OpenRouter (no GPU — won't collide with local Q4 work). Per model:
#   1) swe_agentless_run.sh --subset strat51 --tag orf : localize + repair for the 51 (generates the
#      ~31 missing instances; cached ones skip via --skip_existing) + a baseline Docker eval
#   2) SWE_OR=1 swe_full_select.sh : repro-40 rerank + gold eval on the 51  (matches Q4's config)
# Result per model -> results/scored/<model>-full/swebench_lite.json (n=51). Logs: logs_strat51_<k>.log
set -uo pipefail
cd /home/aliixh/.openclaw/workspace/edge-intelligence-benchmark || exit 1
echo "=== full-precision strat-51 all-5 (parallel) start $(date -u) ===" > logs_strat51_all.log
for k in qwen38 qwen27 gemma muse qwen35; do
  (
    echo "--- $k start $(date -u) ---" >> "logs_strat51_${k}.log"
    bash scripts/swe_agentless_run.sh "$k" --tag orf --subset strat51 >> "logs_strat51_${k}.log" 2>&1 \
      || echo "$k: agentless_run non-zero" >> "logs_strat51_${k}.log"
    SWE_OR=1 bash scripts/swe_full_select.sh "$k" >> "logs_strat51_${k}.log" 2>&1 \
      || echo "$k: full_select non-zero (kept old)" >> "logs_strat51_${k}.log"
    echo "--- $k done $(date -u) ---" >> "logs_strat51_${k}.log"
  ) &
  echo "launched $k (pid $!)" >> logs_strat51_all.log
  sleep 3
done
wait
echo "=== full-precision strat-51 all-5 COMPLETE $(date -u) ===" >> logs_strat51_all.log
