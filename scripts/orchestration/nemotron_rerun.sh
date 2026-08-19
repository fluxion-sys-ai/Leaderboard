#!/bin/bash
# nemotron-3-nano-30b RE-RUN with no_think — the first run (no no_think) dumped think-tokens to the
# cap (mmlu_pro 44% empty, ifeval 20%). no_think:true is now in config. Smoke-test on mmlu_pro (the
# bench that FAILED — not easy ifeval) to verify no_think actually works BEFORE the full grid.
# If the template ignores enable_thinking, smoke stays dirty -> keep hidden + flag, no GPU wasted.
set -u
cd /home/aliixh/edge-intelligence-benchmark
export LLAMACPP_BIN=/home/aliixh/llama.cpp/llama-b9892
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/nemotron_rerun.log
M=nemotron-3-nano-30b
say(){ echo "[nemo-rerun] $(date -u +%T) $*" >> "$L"; }
echo "=== nemotron re-run (no_think) — smoke mmlu_pro -> full if clean ===" > "$L"
GRID="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl simpleqa"

# 0) no_think MUST be in config else the re-run just reproduces the contamination
python3 -c "import yaml,sys;m=[x for x in yaml.safe_load(open('configs/models.yaml'))['models'] if x['name']=='$M'];sys.exit(0 if (m and m[0].get('no_think')) else 1)" \
  || { say "no_think NOT in config -> ABORT"; exit 1; }

# 1) wait for exaone pinch + any GPU job to finish (solo-GPU)
say "waiting for exaone + GPU free"
while pgrep -f "[b]ash /tmp/exaone_pinch_64k.sh" >/dev/null \
   || pgrep -f "[r]un_benchmark.py --models" >/dev/null \
   || pgrep -f "[b]enchmark.py --model openai/edge-" >/dev/null \
   || pgrep -f "[l]lama-server" >/dev/null; do sleep 60; done
say "GPU free -> nemotron re-run"

# 2) scored smoke on mmlu_pro-25 (the bench that failed) WITH no_think
pkill -f "[l]lama-server" 2>/dev/null; sleep 8
rm -f results/scored/$M/mmlu_pro.json results/raw/$M/mmlu_pro.jsonl
python3 run_benchmark.py --models $M --benchmarks mmlu_pro --limit 25 >> "$L" 2>&1
EP=$(python3 - <<'PY'
import json,os
p='results/raw/nemotron-3-nano-30b/mmlu_pro.jsonl'
r=[json.loads(l) for l in open(p)] if os.path.exists(p) else []
e=sum(1 for x in r if not str(x.get('output') or '').strip()); print(round(100*e/len(r)) if r else 100)
PY
)
say "smoke mmlu_pro-25 (no_think): empty=${EP}%"

# 3) decide
if [ "${EP:-100}" -gt 15 ] 2>/dev/null; then
  say "!! no_think did NOT fix it (${EP}% empty) — template likely ignores enable_thinking. KEEP HIDDEN + flag. No full run."
  rm -rf models/$M 2>/dev/null
  exit 0
fi
say "smoke clean (${EP}%) -> FULL grid + pinch@32K"
pkill -f "[l]lama-server" 2>/dev/null; sleep 8
rm -rf results/scored/$M results/raw/$M
python3 run_benchmark.py --models $M --benchmarks $GRID >> "$L" 2>&1 || say "grid errored"
pkill -f "[l]lama-server" 2>/dev/null; sleep 8
say "pinch @ 32K (nemotron is 32K-native)"
PINCH_CTX=32768 FORCE_PINCH=1 bash scripts/pinchbench_run.sh $M >> "$L" 2>&1 || say "pinch skipped/errored"
pkill -f "[l]lama-server" 2>/dev/null; sleep 8
python3 import_pinchbench.py >> "$L" 2>&1

# 4) auto-un-hide if clean (<15% overall), mark 32K pinch spec, rebuild
python3 - <<'PY' >> "$L" 2>&1
import json,os,glob
m='nemotron-3-nano-30b'
def out(r): return str(r.get('output') or '')
T=E=0
for f in glob.glob(f'results/raw/{m}/*.jsonl'):
    if 'clawd' in f: continue
    rows=[json.loads(l) for l in open(f)]; T+=len(rows); E+=sum(1 for r in rows if not out(r).strip())
pe=100*E/T if T else 100
h=json.load(open('configs/hidden_models.json'))
if pe<15 and m in h:
    del h[m]; json.dump(h,open('configs/hidden_models.json','w'),indent=1); print(f"UN-HIDDEN (empty {pe:.0f}%)")
else:
    print(f"kept hidden (empty {pe:.0f}%)")
# mark 32K pinch spec
sp='configs/score_specs.json'
if os.path.exists(f'results/scored/{m}/pinchbench.json'):
    d=json.load(open(sp)); d.setdefault('overrides',{}).setdefault(m,{})['pinchbench']='PinchBench ctx 32K (model is 32K-native, not the standard 128K)'
    json.dump(d,open(sp,'w'),indent=1); print('marked 32K pinch spec')
PY
python3 -m src.report.build_leaderboard >> "$L" 2>&1
cp -f leaderboard.html docs/index.html 2>/dev/null
cp -f leaderboard.html /home/aliixh/.openclaw/workspace/leaderboard.html 2>/dev/null
rm -rf models/$M 2>/dev/null
say "NEMOTRON RE-RUN DONE"
