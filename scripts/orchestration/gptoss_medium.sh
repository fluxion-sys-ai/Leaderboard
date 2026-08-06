#!/bin/bash
# gpt-oss-20b RERUN at reasoning_effort=medium — fixes the harmony empty-final-channel bug that
# understated bfcl (60% empty), babilong (43%), zebralogic (12%) and pinchbench (0.05) at 'low'.
# Runs RIGHT AFTER ornith, BEFORE the qwen fixes. Solo-GPU. Reverts config to low afterwards so
# 'low' stays the documented default; only these 4 scores are marked medium in score_specs.json.
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/gptoss_medium.log
say(){ echo "[gptoss-med] $(date -u +%T) $*" >> "$L"; }
echo "=== gpt-oss-20b reasoning_effort=medium rerun (bfcl babilong zebralogic + pinch) ===" > "$L"

# Gate on GPU-AVAILABILITY, not ornith's script lifecycle: ornith's GPU work is done; its tail is a
# CPU-only rescore_all that must not hold the GPU idle. Start as soon as no GPU inference is active.
say "waiting for the GPU to be free (ornith's CPU rescore can finish in parallel)"
while pgrep -f "run_benchmark.py --models" >/dev/null \
   || pgrep -f "benchmark.py --model openai/edge-" >/dev/null \
   || pgrep -f 'llama-server' >/dev/null; do sleep 60; done
say "GPU free -> starting gpt-oss medium rerun"

# 1) set reasoning_effort: low -> medium (targeted line edit; reasoning_effort only appears once)
sed -i 's/reasoning_effort: low/reasoning_effort: medium/' configs/models.yaml   # inline flow style
if ! python3 -c "import yaml; yaml.safe_load(open('configs/models.yaml'))" 2>/dev/null; then
  say "!! config parse broke setting medium — reverting + ABORT"
  sed -i 's/reasoning_effort: medium/reasoning_effort: low/' configs/models.yaml; exit 1
fi
if ! python3 -c "import yaml,sys;m=[x for x in yaml.safe_load(open('configs/models.yaml'))['models'] if x['name']=='gpt-oss-20b'][0];sys.exit(0 if m['template_kwargs']['reasoning_effort']=='medium' else 1)" 2>/dev/null; then
  say "!! medium not set — ABORT"; exit 1
fi
say "config set to medium OK"

touch /tmp/gptoss_medium.stamp   # only benches rescored AFTER this get marked medium

# 2) clear the 3 contaminated grid benches so run_benchmark regenerates them (not cached)
pkill -f 'llama-server' 2>/dev/null; sleep 8
for b in bfcl babilong zebralogic; do rm -f results/scored/gpt-oss-20b/$b.json results/raw/gpt-oss-20b/$b.jsonl; done
say "grid rerun: bfcl babilong zebralogic (medium via config)"
python3 run_benchmark.py --models gpt-oss-20b --benchmarks bfcl babilong zebralogic >> "$L" 2>&1 || say "gpt-oss grid rerun errored"

# 3) pinch at explicit medium (env-driven arg added to pinchbench_run.sh)
pkill -f 'llama-server' 2>/dev/null; sleep 8
say "pinch rerun @ reasoning_effort=medium"
REASONING_EFFORT=medium bash scripts/pinchbench_run.sh gpt-oss-20b >> "$L" 2>&1 || say "gpt-oss pinch rerun skipped/errored"
pkill -f 'llama-server' 2>/dev/null; sleep 8
python3 import_pinchbench.py >> "$L" 2>&1

# 4) revert config to low (documented default)
sed -i 's/reasoning_effort: medium/reasoning_effort: low/' configs/models.yaml
python3 -c "import yaml; yaml.safe_load(open('configs/models.yaml'))" 2>/dev/null || say "WARN: config parse after revert"
say "config reverted to low"

# 5) mark ONLY the freshly-regenerated benches as medium in score_specs.json
python3 - <<'PY' >> "$L" 2>&1
import json,os
stamp=os.path.getmtime('/tmp/gptoss_medium.stamp')
sp='configs/score_specs.json'
d=json.load(open(sp)) if os.path.exists(sp) else {"universal":{},"overrides":{}}
ov=d.setdefault("overrides",{}).setdefault("gpt-oss-20b",{})
note="reasoning_effort=medium (default is low; re-run to fix harmony empty-final-channel bug)"
marked=[]
for b in ["bfcl","babilong","zebralogic","pinchbench"]:
    p=f"results/scored/gpt-oss-20b/{b}.json"
    if os.path.exists(p) and os.path.getmtime(p)>stamp:
        ov[b]=note; marked.append(b)
json.dump(d,open(sp,'w'),indent=1)
print("marked medium:",marked)
PY

# 6) rebuild + free disk
python3 -m src.report.build_leaderboard >> "$L" 2>&1
cp -f leaderboard.html /home/ubuntu/.openclaw/workspace/leaderboard.html 2>/dev/null
rm -rf models/gpt-oss-20b 2>/dev/null
say "GPT-OSS MEDIUM RERUN DONE"
