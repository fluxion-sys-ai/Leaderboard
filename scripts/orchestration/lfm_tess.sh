#!/bin/bash
# TAIL GRID RERUNS (dead last) — de-contaminate 4 understated models, then auto-un-hide the ones
# that come back clean:
#   tess-4-9b     : no_think:true  (Qwen3.5 finetune — kills thinking-dump empties)
#   lfm2.5-8b-a1b : max_tokens_mult:4  (was truncating at 1x cap)
#   qwen3-8b      : no_think:true + max_tokens_mult:3  (grid ran pre-no_think)   [HIDDEN -> unhide if clean]
#   gemma-4-12b   : no_think:true  (grid ran pre-no_think, 62% empty)            [HIDDEN -> unhide if clean]
# Grid only (all bottom/mid-tier -> pinch gate skips). Un-hide = remove from configs/hidden_models.json
# only if the fresh grid is <15% empty, so a still-broken model STAYS hidden.
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/lfm_tess.log
say(){ echo "[tail-reruns] $(date -u +%T) $*" >> "$L"; }
echo "=== tail grid reruns: tess, lfm2.5, qwen3-8b, gemma-4-12b — dead last ===" > "$L"
BENCH="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl simpleqa"

say "waiting for all other jobs (ornith/gptoss/qwen/gemma-31b/gemma-e4b) to finish"
while ps -eo cmd | grep -qE "bash /tmp/(ornith_rerun|gptoss_medium|qwen_128k_fix|gemma_last|gemma_e4b)\.sh$" \
   || pgrep -f "run_benchmark.py --models" >/dev/null \
   || pgrep -f "benchmark.py --model openai/edge-" >/dev/null; do sleep 300; done
say "everything else done -> tail reruns"

# sanity: the four fixes must be in config, else a rerun just reproduces the contamination
python3 - <<'PY' || { echo "[tail-reruns] config fixes missing — ABORT" >> /tmp/lfm_tess.log; exit 1; }
import yaml,sys
ms={m['name']:m for m in yaml.safe_load(open('configs/models.yaml'))['models']}
ok = (ms['tess-4-9b'].get('no_think') and ms['lfm2.5-8b-a1b'].get('max_tokens_mult')==4
      and ms['qwen3-8b'].get('no_think') and ms['gemma-4-12b'].get('no_think'))
sys.exit(0 if ok else 1)
PY

for M in tess-4-9b lfm2.5-8b-a1b qwen3-8b gemma-4-12b; do
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  rm -rf results/scored/$M results/raw/$M
  say "$M grid rerun"
  python3 run_benchmark.py --models $M --benchmarks $BENCH >> "$L" 2>&1 || say "$M grid errored"
  # auto-un-hide if the fresh grid is clean (<15% empty)
  python3 - "$M" <<'PY' >> "$L" 2>&1
import json,glob,os,sys
m=sys.argv[1]
def out(r): return str(r.get('output') or '')
tot=emp=0
for f in glob.glob(f'results/raw/{m}/*.jsonl'):
    for l in open(f):
        r=json.loads(l); tot+=1
        if not out(r).strip(): emp+=1
pe=100*emp/tot if tot else 100.0
hp='configs/hidden_models.json'
h=json.load(open(hp)) if os.path.exists(hp) else {}
if tot and pe<15 and m in h:
    del h[m]; json.dump(h,open(hp,'w'),indent=1); print(f'  [{m}] empty {pe:.0f}% -> UN-HIDDEN')
else:
    print(f'  [{m}] empty {pe:.0f}% (tot={tot}) -> {"kept hidden (still dirty)" if m in h else "not hidden"}')
PY
  rm -rf models/$M 2>/dev/null
done

python3 judge_writing.py  >> "$L" 2>&1
python3 judge_simpleqa.py >> "$L" 2>&1
python3 rescore_all.py    >> "$L" 2>&1
python3 -m src.report.build_leaderboard >> "$L" 2>&1
cp -f leaderboard.html /home/ubuntu/.openclaw/workspace/leaderboard.html 2>/dev/null
say "TAIL RERUNS DONE — everything complete"
