#!/bin/bash
# granite-4.1-30b PinchBench — was deadline-dropped from pinch_batch. No time pressure now.
# Runs after pinch_batch2. Dense-30B, so OOM@128K -> retry @64K (◆). 128K clamp-guarded.
set -u
cd /home/aliixh/edge-intelligence-benchmark
export LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/granite_pinch.log
say(){ echo "[granite-pinch] $(date -u +%T) $*" >> "$L"; }
echo "=== granite-4.1-30b pinch (post-deadline) — $(date -u) ===" > "$L"
M=granite-4.1-30b

say "waiting for pinch_batch2 + GPU free"
while pgrep -f "[b]ash /tmp/pinch_batch2.sh" >/dev/null \
   || pgrep -f "[r]un_benchmark.py --models" >/dev/null \
   || pgrep -f "[b]enchmark.py --model openai/edge-" >/dev/null \
   || pgrep -f "[l]lama-server" >/dev/null; do sleep 90; done
say "GPU free -> granite pinch"

pkill -f "[l]lama-server" 2>/dev/null; sleep 8
PL=/tmp/pb_${M}.log
FORCE_PINCH=1 bash scripts/pinchbench_run.sh $M > "$PL" 2>&1 || say "$M pinch@128K errored"
nctx=$(grep -oE "clamp-guard OK: n_ctx=[0-9]+|CLAMP DETECTED: server n_ctx=[0-9]+" "$PL" | grep -oE "[0-9]+" | head -1)
if [ ! -f results/scored/$M/pinchbench.json ] && grep -qiE "out of memory|oom|OutOfDeviceMemory" "$PL"; then
  say "$M OOM@128K -> retry @64K"
  pkill -f "[l]lama-server" 2>/dev/null; sleep 8
  PINCH_CTX=65536 FORCE_PINCH=1 bash scripts/pinchbench_run.sh $M >> "$PL" 2>&1
  python3 - "$M" <<'PY' >> "$L" 2>&1
import json,os,sys; m=sys.argv[1]; sp='configs/score_specs.json'
if os.path.exists(f'results/scored/{m}/pinchbench.json'):
    d=json.load(open(sp)); d.setdefault('overrides',{}).setdefault(m,{})['pinchbench']='PinchBench ctx 64K (128K KV OOMs the 40GB card)'
    json.dump(d,open(sp,'w'),indent=1); print('marked 64K')
PY
fi
pkill -f "[l]lama-server" 2>/dev/null; sleep 8
python3 import_pinchbench.py >> "$L" 2>&1
tnf=$(grep -c "Transcript not found" "$PL" 2>/dev/null || echo 0)
ps=$(python3 -c "import json,os;p='results/scored/$M/pinchbench.json';print(round(json.load(open(p))['score'],3)) if os.path.exists(p) else print('none')" 2>/dev/null)
say "$M pinch=$ps (transcript-not-found=$tnf, n_ctx=${nctx:-?})"
if [ "${tnf:-0}" -gt 50 ] 2>/dev/null; then
  rm -f results/scored/$M/pinchbench.json
  say "!! FLAG: $M transcript-not-found bug ($tnf) -> DISCARDED pinch, agentic stays BFCL"
fi
python3 -m src.report.build_leaderboard >> "$L" 2>&1
cp -f leaderboard.html docs/index.html 2>/dev/null; cp -f leaderboard.html /home/aliixh/.openclaw/workspace/leaderboard.html 2>/dev/null
git add configs/ leaderboard.html docs/index.html results/scored/$M results/raw/$M >> "$L" 2>&1
git -c user.name=aliixh -c user.email=aliixhuang@gmail.com commit -q -m "pinch: PinchBench for granite-4.1-30b ($ps) — completes coverage (was deadline-dropped)" >> "$L" 2>&1 && git push origin main >> "$L" 2>&1 && say "committed+pushed"
rm -rf models/$M 2>/dev/null
say "GRANITE PINCH DONE ($(date -u))"
