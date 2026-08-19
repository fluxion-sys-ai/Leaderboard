#!/bin/bash
# DEADLINE-AWARE pinch batch — add PinchBench (128K, clamp-guarded) to the 4 grid-only top models.
# Deadline: Mon 2026-08-10 15:00 UTC (8 AM PT). Rules to guarantee we finish in time:
#  - per-model 3h wall-clock CAP (timeout) -> if a model runs long, KILL + skip + FLAG (try next model)
#  - don't START a model if <2h to deadline (it can't finish) -> skip it, leave agentic=BFCL (safe/honest)
#  - order fast+safe first, granite (dense-30B, slowest, OOM-risk) LAST so it's the one dropped if late
#  - OOM@128K -> retry @64K (marked ◆); transcript-not-found bug -> discard artifact pinch
#  - 128K is enforced by pinchbench_run.sh's clamp-guard (skips if n_ctx<100k); we log the n_ctx too
set -u
cd /home/aliixh/edge-intelligence-benchmark
export LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/pinch_batch.log
say(){ echo "[pinch] $(date -u +%T) $*" >> "$L"; }
DEADLINE=$(date -u -d '2026-08-10 15:00:00' +%s)
CAP=10800   # 3h per model
echo "=== deadline-aware pinch batch (deadline $(date -u -d @$DEADLINE)) — $(date -u) ===" > "$L"
MODELS="devstral-small-2-24b gemma-4-12b gemma-4-26b-a4b granite-4.1-30b"

say "waiting for fill_batch + GPU free"
while pgrep -f "[b]ash /tmp/fill_batch.sh" >/dev/null \
   || pgrep -f "[r]un_benchmark.py --models" >/dev/null \
   || pgrep -f "[b]enchmark.py --model openai/edge-" >/dev/null \
   || pgrep -f "[l]lama-server" >/dev/null; do sleep 90; done
say "GPU free -> pinch batch"

for M in $MODELS; do
  remain=$(( (DEADLINE - $(date +%s)) / 60 ))
  if [ "$remain" -lt 180 ]; then say "!! FLAG: only ${remain}min left (<3h) to 8AM deadline -> SKIP $M and rest (they stay BFCL-only, honest). Not risking a partial."; break; fi
  FREE=$(df --output=avail -BG /home/aliixh | tail -1 | tr -dc '0-9')
  [ "${FREE:-0}" -lt 30 ] && { say "!! FLAG: ${FREE}G disk -> STOP"; break; }
  say "=== $M pinch === (${remain}min to deadline, ${FREE}G free)"
  pkill -f "[l]lama-server" 2>/dev/null; sleep 8
  PL=/tmp/pb_${M}.log
  timeout $CAP env FORCE_PINCH=1 bash scripts/pinchbench_run.sh $M > "$PL" 2>&1
  rc=$?
  nctx=$(grep -oE "clamp-guard OK: n_ctx=[0-9]+|CLAMP DETECTED: server n_ctx=[0-9]+" "$PL" | grep -oE "[0-9]+" | head -1)
  say "$M rc=$rc n_ctx=${nctx:-unread}"
  if [ "$rc" = "124" ]; then
    say "!! FLAG: $M pinch exceeded 3h cap -> KILLED, moving to next model (agentic stays BFCL). Something's off with $M pinch speed."
    pkill -f "[l]lama-server" 2>/dev/null; sleep 8; rm -f results/scored/$M/pinchbench.json; continue
  fi
  # OOM@128K -> retry @64K (if time remains)
  if [ ! -f results/scored/$M/pinchbench.json ] && grep -qiE "out of memory|oom|OutOfDeviceMemory" "$PL" && [ "$(( (DEADLINE-$(date +%s))/60 ))" -gt 150 ]; then
    say "$M OOM@128K -> retry @64K"
    pkill -f "[l]lama-server" 2>/dev/null; sleep 8
    timeout $CAP env PINCH_CTX=65536 FORCE_PINCH=1 bash scripts/pinchbench_run.sh $M >> "$PL" 2>&1
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
    say "!! FLAG: $M hit transcript-not-found bug ($tnf skipped) -> DISCARDED pinch, agentic stays BFCL (like exaone)"
  fi
  python3 -m src.report.build_leaderboard >> "$L" 2>&1
  cp -f leaderboard.html docs/index.html 2>/dev/null; cp -f leaderboard.html /home/aliixh/.openclaw/workspace/leaderboard.html 2>/dev/null
  git add configs/ leaderboard.html docs/index.html results/scored/$M results/raw/$M >> "$L" 2>&1
  git -c user.name=aliixh -c user.email=aliixhuang@gmail.com commit -q -m "pinch: PinchBench for $M ($ps, 128K) — completes agentic" >> "$L" 2>&1 && git push origin main >> "$L" 2>&1 && say "$M committed+pushed"
  rm -rf models/$M 2>/dev/null
  say "$M DONE"
done
say "PINCH BATCH COMPLETE ($(date -u))"
