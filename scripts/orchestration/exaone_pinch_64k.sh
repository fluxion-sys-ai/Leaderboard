#!/bin/bash
# exaone-4.5-33b PinchBench @ 64K — the 128K run OOM'd (33B dense + 128K KV > 40GB card). 64K KV
# fits (~33GB total). Runs DEAD LAST, after every other job. FORCE gate. Marks a ◆ spec deviation
# (ran at 64K, not the usual 128K) on the board.
set -u
cd /home/aliixh/edge-intelligence-benchmark
export LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/exaone_pinch_64k.log
say(){ echo "[exaone-64k] $(date -u +%T) $*" >> "$L"; }
echo "=== exaone-4.5-33b PinchBench @ 64K (128K OOM'd) — dead last ===" > "$L"

say "waiting for gemma_last + gemma_e4b + lfm_tess + GPU to all finish"
while ps -eo cmd | grep -qE "bash /tmp/(gemma_last|lfm_tess|nemotron_test)\.sh$" \
   || pgrep -f "run_benchmark.py --models" >/dev/null \
   || pgrep -f "benchmark.py --model openai/edge-" >/dev/null \
   || pgrep -f 'llama-server' >/dev/null; do sleep 60; done
say "GPU free -> exaone pinch @ 64K (FORCE)"

pkill -f 'llama-server' 2>/dev/null; sleep 8
PINCH_CTX=65536 FORCE_PINCH=1 bash scripts/pinchbench_run.sh exaone-4.5-33b >> "$L" 2>&1 || say "exaone 64K pinch errored (OOM again? check pb_llama log)"
pkill -f 'llama-server' 2>/dev/null; sleep 8
python3 import_pinchbench.py >> "$L" 2>&1
PS=$(python3 -c "import json;print(json.load(open('results/scored/exaone-4.5-33b/pinchbench.json'))['score'])" 2>/dev/null || echo NA)
say "exaone pinch @64K = $PS"

# mark the ◆ spec deviation (ran at 64K, not 128K) if a score landed
python3 - <<'PY' >> "$L" 2>&1
import json,os
p='results/scored/exaone-4.5-33b/pinchbench.json'; sp='configs/score_specs.json'
if os.path.exists(p):
    d=json.load(open(sp))
    d.setdefault('overrides',{}).setdefault('exaone-4.5-33b',{})['pinchbench']='PinchBench ctx 64K (not the standard 128K) — 33B dense + 128K KV OOMs the 40GB card'
    json.dump(d,open(sp,'w'),indent=1); print('marked exaone pinch 64K spec deviation')
PY
python3 -m src.report.build_leaderboard >> "$L" 2>&1
cp -f leaderboard.html /home/aliixh/.openclaw/workspace/leaderboard.html 2>/dev/null
cp -f leaderboard.html docs/index.html 2>/dev/null
rm -rf models/exaone-4.5-33b 2>/dev/null
say "EXAONE 64K PINCH DONE — everything complete"
