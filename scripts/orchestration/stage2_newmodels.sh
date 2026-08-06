#!/bin/bash
set -u
cd /home/ubuntu/edge-intelligence-benchmark
export HF_TOKEN="$(cat .hf_token 2>/dev/null)"
export LLAMACPP_BIN=/home/ubuntu/llama.cpp/llama-b9892
export OPENROUTER_API_KEY="$(cat .openrouter_key 2>/dev/null)"
L=/tmp/stage2_newmodels.log
say(){ echo "[stage2] $(date -u +%T) $*" >> "$L"; }
echo "=== stage2: 7 new models (option A: download -> run -> delete each) ===" > "$L"
BENCH="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl simpleqa"
# order: wave-1 generalists, wave-2 new lineages, gpt-oss LAST (harmony smoke risk). "model:GBneeded"
# CUT to 3 for <2-day target (shujun 2026-08-04). Dropped: gemma-4-31b, devstral-small-2-24b,
# granite-4.1-30b, gemma-4-26b-a4b — still registered in models.yaml, re-add here to run later.
# 3 core models for <2-day target; gemma-4-31b appended as a BONUS (runs only after the 3,
# so it never delays the deliverable — pure "extra time" overflow per shujun).
# mistral DONE (kept). exaone restarted with no_think fix (2026-08-05). gpt-oss + gemma still queued.
MODELS="exaone-4.5-33b:22 gpt-oss-20b:15"

# 0) wait for the redo chain to finish (solo-GPU)
say "waiting for redo chain (chain_context_redos.sh) to finish"
while pgrep -f chain_context_redos.sh >/dev/null; do sleep 300; done
say "redo chain done -> starting 7 new-model adds"

# 1) reclaim SAFE junk only (my spec-decode drafts + unused perfectblend cache). Nothing cross-project.
say "reclaiming safe disk: spec-decode drafts + open-perfectblend cache"
rm -rf models/draft_* models/*_draft 2>/dev/null
rm -rf /home/ubuntu/.cache/huggingface/hub/datasets--mlabonne--open-perfectblend 2>/dev/null
df -h /home/ubuntu | tail -1 >> "$L"

# 2) per model: disk-gate -> grid (auto-downloads) -> load-gate -> pinchbench -> import -> build -> delete
for entry in $MODELS; do
  M="${entry%%:*}"; NEED="${entry##*:}"
  pkill -f 'llama-server' 2>/dev/null; sleep 8
  AVAIL=$(df --output=avail -BG /home/ubuntu | tail -1 | tr -dc 0-9)
  if [ "${AVAIL:-0}" -lt "$NEED" ]; then
    say "!! $M SKIPPED: disk ${AVAIL}G < needed ${NEED}G. Free cross-project space (qwen3.5-9b/nanbeige/specdecode_data) then rerun this model."
    continue
  fi
  say "=== $M: grid (auto-pulls GGUF ~${NEED}G; ${AVAIL}G free) ==="
  python3 run_benchmark.py --models "$M" --benchmarks $BENCH >> "$L" 2>&1 || say "$M grid errored"
  if ls results/scored/$M/*.json >/dev/null 2>&1; then
    say "$M loaded OK -> PinchBench @128K"
    pkill -f 'llama-server' 2>/dev/null; sleep 8
    bash scripts/pinchbench_run.sh "$M" >> "$L" 2>&1 || say "$M pinchbench errored"
    pkill -f 'llama-server' 2>/dev/null; sleep 8
    python3 import_pinchbench.py >> "$L" 2>&1
  else
    say "!! $M produced NO grid scores -> arch/load FAIL (novel arch on b9892? EXAONE/exaone4_5, gpt-oss). Skipping PinchBench. FLAG."
  fi
  python3 -m src.report.build_leaderboard >> "$L" 2>&1
  say "$M finished -> deleting weights (models/$M) to free disk for next"
  rm -rf "models/$M" 2>/dev/null
  df -h /home/ubuntu | tail -1 >> "$L"
done
cp -f leaderboard.html /home/ubuntu/edge_leaderboard.html 2>/dev/null
say "STAGE2 ALL DONE — review: gpt-oss (harmony), EXAONE (rope long-ctx) grid scores for sanity"
