#!/bin/bash
# Add PinchBench to the top models that ran grid-only (fill_batch skipped pinch). Priority devstral
# (agentic-coding specialist). Per model: run pinch @128K (retry @64K on OOM) -> guard against the
# transcript-not-found harness bug (discard pinch if it hits, keep agentic=BFCL) -> import+rebuild+push
# -> free GGUF. Waits for fill_batch (devstral grid + qwen3.5-4b) to finish first. Solo-GPU.
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/pinch_batch.log
say(){ echo "[pinch] $(date -u +%T) $*" >> "$L"; }
echo "=== pinch batch (grid-only top models) — $(date -u) ===" > "$L"
MODELS="devstral-small-2-24b gemma-4-26b-a4b gemma-4-12b granite-4.1-30b"

say "waiting for fill_batch + GPU free"
while pgrep -f "[b]ash /tmp/fill_batch.sh" >/dev/null \
   || pgrep -f "[r]un_benchmark.py --models" >/dev/null \
   || pgrep -f "[b]enchmark.py --model openai/edge-" >/dev/null \
   || pgrep -f "[l]lama-server" >/dev/null; do sleep 90; done
say "GPU free -> pinch batch"

for M in $MODELS; do
  FREE=$(df --output=avail -BG /home/ubuntu | tail -1 | tr -dc '0-9')
  [ "${FREE:-0}" -lt 30 ] && { say "!! ${FREE}G free -> STOP (disk)"; break; }
  say "=== $M pinch (${FREE}G free) ==="
  pkill -f "[l]lama-server" 2>/dev/null; sleep 8
  PL=/tmp/pb_${M}.log
  FORCE_PINCH=1 bash scripts/pinchbench_run.sh $M > "$PL" 2>&1 || say "$M pinch@128K errored"
  # OOM fallback -> 64K (dense-30B like granite may not fit 128K KV)
  if [ ! -f results/scored/$M/pinchbench.json ] && grep -qiE "out of memory|oom|OutOfDeviceMemory" "$PL"; then
    say "$M OOM@128K -> retry @64K"
    pkill -f "[l]lama-server" 2>/dev/null; sleep 8
    PINCH_CTX=65536 FORCE_PINCH=1 bash scripts/pinchbench_run.sh $M >> "$PL" 2>&1 || say "$M pinch@64K errored"
    python3 - "$M" <<'PY' >> "$L" 2>&1
import json,os,sys; m=sys.argv[1]; sp='configs/score_specs.json'
if os.path.exists(f'results/scored/{m}/pinchbench.json'):
    d=json.load(open(sp)); d.setdefault('overrides',{}).setdefault(m,{})['pinchbench']='PinchBench ctx 64K (128K KV OOMs the 40GB card)'
    json.dump(d,open(sp,'w'),indent=1); print('marked 64K spec')
PY
  fi
  pkill -f "[l]lama-server" 2>/dev/null; sleep 8
  python3 import_pinchbench.py >> "$L" 2>&1
  tnf=$(grep -c "Transcript not found" "$PL" 2>/dev/null || echo 0)
  ps=$(python3 -c "import json,os;p='results/scored/$M/pinchbench.json';print(round(json.load(open(p))['score'],3)) if os.path.exists(p) else print('none')" 2>/dev/null)
  say "$M pinch=$ps (transcript-not-found=$tnf)"
  # transcript-bug guard: if most tasks skipped, the pinch is an artifact -> discard (keep bfcl-only agentic)
  if [ "${tnf:-0}" -gt 50 ] 2>/dev/null; then
    rm -f results/scored/$M/pinchbench.json
    say "$M transcript-not-found bug ($tnf skipped) -> DISCARDED pinch (agentic stays BFCL-only, like exaone)"
  fi
  python3 -m src.report.build_leaderboard >> "$L" 2>&1
  cp -f leaderboard.html docs/index.html 2>/dev/null; cp -f leaderboard.html /home/ubuntu/.openclaw/workspace/leaderboard.html 2>/dev/null
  git add configs/ leaderboard.html docs/index.html results/scored/$M results/raw/$M >> "$L" 2>&1
  git -c user.name=aliixh -c user.email=aliixhuang@gmail.com commit -q -m "pinch: PinchBench for $M ($ps) — completes its agentic score" >> "$L" 2>&1 && git push origin main >> "$L" 2>&1 && say "$M committed+pushed"
  rm -rf models/$M 2>/dev/null
  say "$M DONE"
done
say "PINCH BATCH COMPLETE"
