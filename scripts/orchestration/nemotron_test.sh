#!/bin/bash
# Nemotron-3-Nano-30B-A3B — smoke-test → auto-adjust settings if numbers are off → full run if good.
# Runs DEAD LAST (after exaone_pinch_64k). 30B MoE, 32K-native, small KV (no 128K OOM).
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/nemotron_test.log
M=nemotron-3-nano-30b
say(){ echo "[nemotron] $(date -u +%T) $*" >> "$L"; }
echo "=== Nemotron-3-Nano-30B: smoke → auto-adjust → full run (dead last) ===" > "$L"
GRID="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl simpleqa"

ep(){ python3 - "$M/ifeval" <<'PY'
import json,sys,os
m,b=sys.argv[1].split('/'); p=f'results/raw/{m}/{b}.jsonl'
r=[json.loads(l) for l in open(p)] if os.path.exists(p) else []
e=sum(1 for x in r if not str(x.get('output') or '').strip()); print(round(100*e/len(r)) if r else 100)
PY
}
smoke(){   # scored 25-task ifeval smoke -> sets EP (empty%) and SC (score)
  rm -f results/scored/$M/ifeval.json results/raw/$M/ifeval.jsonl
  python3 run_benchmark.py --models $M --benchmarks ifeval --limit 25 >> "$L" 2>&1
  EP=$(ep); SC=$(python3 -c "import json;print(json.load(open('results/scored/$M/ifeval.json'))['score'])" 2>/dev/null||echo NA)
}

# 1) wait for ALL prior jobs + GPU
say "waiting for all prior jobs + GPU free"
while ps -eo cmd | grep -qE "bash /tmp/(gemma_last|lfm_tess)\.sh$" \
   || pgrep -f "run_benchmark.py --models" >/dev/null \
   || pgrep -f "benchmark.py --model openai/edge-" >/dev/null \
   || pgrep -f 'llama-server' >/dev/null; do sleep 60; done
say "GPU free -> nemotron"

# 2) preflight (catches an unsupported-arch load fail cheaply, like gemma-4-31b's first try)
pkill -f 'llama-server' 2>/dev/null; sleep 8
PF=$(python3 scripts/preflight.py $M 2>>"$L"); say "preflight: $PF"
pkill -f 'llama-server' 2>/dev/null; sleep 8
if echo "$PF" | grep -q 'LOAD FAIL'; then say "!! LOAD FAIL — arch unsupported on b9892 -> FLAG + SKIP"; exit 0; fi

# 3) scored smoke + ONE auto-adjust (add no_think if it's dumping empty output)
pkill -f 'llama-server' 2>/dev/null; sleep 8
smoke; say "smoke ifeval-25: empty=${EP}% score=$SC"
if [ "${EP:-100}" -gt 25 ] 2>/dev/null; then
  say "numbers off (${EP}% empty) -> auto-adjust: add no_think:true, re-smoke"
  sed -i '/lmstudio-community\/NVIDIA-Nemotron-3-Nano-30B-A3B-GGUF/a\    no_think: true   # auto-added after empty smoke' configs/models.yaml
  python3 -c "import yaml;yaml.safe_load(open('configs/models.yaml'))" 2>/dev/null || { say "config broke on no_think add — ABORT"; exit 1; }
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  smoke; say "smoke#2 (no_think) ifeval-25: empty=${EP}% score=$SC"
fi
if [ "${EP:-100}" -gt 25 ] 2>/dev/null; then
  say "!! still ${EP}% empty after adjust -> FLAG + SKIP full run (no GPU wasted)"; exit 0
fi

# 4) GOOD -> full grid + pinch (32K native)
say "smoke clean (empty=${EP}% score=$SC) -> FULL grid + pinch"
pkill -f 'llama-server' 2>/dev/null; sleep 8
rm -rf results/scored/$M results/raw/$M
python3 run_benchmark.py --models $M --benchmarks $GRID >> "$L" 2>&1 || say "grid errored"
pkill -f 'llama-server' 2>/dev/null; sleep 8
say "pinch @ 32K (Nemotron is 32K-native, not 128K)"
PINCH_CTX=32768 FORCE_PINCH=1 bash scripts/pinchbench_run.sh $M >> "$L" 2>&1 || say "pinch skipped/errored"
pkill -f 'llama-server' 2>/dev/null; sleep 8
python3 import_pinchbench.py >> "$L" 2>&1
python3 - <<'PY' >> "$L" 2>&1
import json,os
p='results/scored/nemotron-3-nano-30b/pinchbench.json'; sp='configs/score_specs.json'
if os.path.exists(p):
    d=json.load(open(sp)); d.setdefault('overrides',{}).setdefault('nemotron-3-nano-30b',{})['pinchbench']='PinchBench ctx 32K (model is 32K-native, not the standard 128K)'
    json.dump(d,open(sp,'w'),indent=1); print('marked nemotron pinch 32K spec')
PY
python3 -m src.report.build_leaderboard >> "$L" 2>&1
cp -f leaderboard.html /home/ubuntu/.openclaw/workspace/leaderboard.html 2>/dev/null
cp -f leaderboard.html docs/index.html 2>/dev/null
rm -rf models/$M 2>/dev/null
say "NEMOTRON DONE"
