#!/bin/bash
# UNATTENDED 14h fill: benchmark the remaining unscheduled models, one at a time, solo-GPU.
# Each model self-configures via a gated smoke on mmlu_pro (the bench that exposes think-dump
# contamination). Order: interesting big models first. Grid-only (no pinch) to fit more in the window.
# Per model: preflight -> smoke -> auto no_think -> auto max_tokens -> full grid if clean -> un-hide
#            -> commit+push -> free the GGUF. Skips+flags cleanly on load-fail or un-fixable empties.
set -u
cd /home/aliixh/edge-intelligence-benchmark
export LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/fill_batch.log
say(){ echo "[fill] $(date -u +%T) $*" >> "$L"; }
echo "=== unattended fill batch — $(date -u) ===" > "$L"
MODELS="gemma-4-26b-a4b granite-4.1-30b devstral-small-2-24b qwen3.5-4b nanbeige4.2-3b"
GRID="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl simpleqa"

empty_of(){ python3 - "$1" "$2" <<'PY'
import json,sys,os
m,b=sys.argv[1],sys.argv[2]; p=f'results/raw/{m}/{b}.jsonl'
r=[json.loads(l) for l in open(p)] if os.path.exists(p) else []
e=sum(1 for x in r if not str(x.get('output') or '').strip()); print(round(100*e/len(r)) if r else 100)
PY
}
gpu_free(){ ! pgrep -f "[b]ash /tmp/exaone_pinch_64k.sh" >/dev/null \
  && ! pgrep -f "[b]ash /tmp/nemotron_rerun.sh" >/dev/null \
  && ! pgrep -f "[r]un_benchmark.py --models" >/dev/null \
  && ! pgrep -f "[b]enchmark.py --model openai/edge-" >/dev/null \
  && ! pgrep -f "[l]lama-server" >/dev/null; }

# wait for the current queue (exaone pinch + nemotron rerun) to fully finish
say "waiting for exaone + nemotron_rerun + GPU"
while ! gpu_free; do sleep 90; done
say "GPU free -> starting fill batch"

for M in $MODELS; do
  # disk guard: need >=30G free to pull a model
  FREE=$(df --output=avail -BG /home/aliixh | tail -1 | tr -dc '0-9')
  if [ "${FREE:-0}" -lt 30 ]; then say "!! only ${FREE}G free -> STOP (disk)"; break; fi
  say "=== $M === (${FREE}G free)"
  pkill -f "[l]lama-server" 2>/dev/null; sleep 8

  # hide it up-front so partial/contaminated data never shows a fake rank
  python3 -c "import json;p='configs/hidden_models.json';h=json.load(open(p));h['$M']='fill-batch: running, hidden until clean+complete';json.dump(h,open(p,'w'),indent=1)"

  # 1) preflight — cheap load/arch check
  PF=$(python3 scripts/preflight.py $M 2>>"$L"); say "$M preflight: $PF"
  if echo "$PF" | grep -q 'LOAD FAIL'; then say "$M LOAD FAIL (arch unsupported on b9892) -> SKIP"; rm -rf models/$M 2>/dev/null; continue; fi

  # 2) gated smoke on mmlu_pro-25, auto-config up to 2 tries
  fix_applied=""
  for attempt in 1 2 3; do
    pkill -f "[l]lama-server" 2>/dev/null; sleep 8
    rm -f results/scored/$M/mmlu_pro.json results/raw/$M/mmlu_pro.jsonl
    python3 run_benchmark.py --models $M --benchmarks mmlu_pro --limit 25 >> "$L" 2>&1
    EP=$(empty_of $M mmlu_pro); say "$M smoke#$attempt mmlu_pro-25: empty=${EP}%${fix_applied}"
    [ "${EP:-100}" -le 15 ] 2>/dev/null && break
    if [ "$attempt" = "1" ]; then
      python3 -c "import yaml;d=yaml.safe_load(open('configs/models.yaml'));[m.update({'no_think':True}) for m in d['models'] if m['name']=='$M'];yaml.safe_dump(d,open('configs/models.yaml','w'),sort_keys=False,default_flow_style=False)" 2>/dev/null && fix_applied=" (+no_think)"
    elif [ "$attempt" = "2" ]; then
      python3 -c "import yaml;d=yaml.safe_load(open('configs/models.yaml'));[m.update({'max_tokens_mult':4}) for m in d['models'] if m['name']=='$M'];yaml.safe_dump(d,open('configs/models.yaml','w'),sort_keys=False,default_flow_style=False)" 2>/dev/null && fix_applied=" (+no_think+maxtok4)"
    fi
  done
  if [ "${EP:-100}" -gt 15 ] 2>/dev/null; then say "$M still ${EP}% empty after auto-config -> KEEP HIDDEN + flag, SKIP full run"; rm -rf models/$M 2>/dev/null; continue; fi

  # 3) full grid
  say "$M smoke clean (${EP}%) -> FULL grid"
  pkill -f "[l]lama-server" 2>/dev/null; sleep 8
  rm -rf results/scored/$M results/raw/$M
  python3 run_benchmark.py --models $M --benchmarks $GRID >> "$L" 2>&1 || say "$M grid errored"

  # 4) un-hide if clean (<15% overall), rebuild, commit+push
  pkill -f "[l]lama-server" 2>/dev/null; sleep 8
  python3 - "$M" <<'PY' >> "$L" 2>&1
import json,os,glob,sys
m=sys.argv[1]
def out(r): return str(r.get('output') or '')
T=E=0
COUNTED="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl".split()
for f in glob.glob(f'results/raw/{m}/*.jsonl'):
    if 'clawd' in f: continue
    rows=[json.loads(l) for l in open(f)]; T+=len(rows); E+=sum(1 for r in rows if not out(r).strip())
pe=100*E/T if T else 100
have={os.path.basename(f)[:-5] for f in glob.glob(f'results/scored/{m}/*.json')}
missing=[b for b in COUNTED if b not in have]   # COMPLETENESS gate: never un-hide a partial grid
h=json.load(open('configs/hidden_models.json'))
if pe<15 and not missing and m in h:
    del h[m]; json.dump(h,open('configs/hidden_models.json','w'),indent=1); print(f"{m} UN-HIDDEN (empty {pe:.0f}%, 14/14 counted)")
else:
    print(f"{m} kept hidden (empty {pe:.0f}%, missing={missing})")
PY
  python3 judge_writing.py >> "$L" 2>&1; python3 judge_simpleqa.py >> "$L" 2>&1
  python3 -m src.report.build_leaderboard >> "$L" 2>&1
  cp -f leaderboard.html docs/index.html 2>/dev/null
  cp -f leaderboard.html /home/aliixh/.openclaw/workspace/leaderboard.html 2>/dev/null
  git add configs/ leaderboard.html docs/index.html results/scored/$M results/raw/$M >> "$L" 2>&1
  git -c user.name=aliixh -c user.email=aliixhuang@gmail.com commit -q -m "fill-batch: add $M to board (auto-configured, clean grid)" >> "$L" 2>&1 && git push origin main >> "$L" 2>&1 && say "$M committed+pushed"
  rm -rf models/$M 2>/dev/null
  say "$M DONE"
done
say "FILL BATCH COMPLETE"
