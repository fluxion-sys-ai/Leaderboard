#!/bin/bash
# SWE-bench Lite via the Agentless pipeline (localize -> repair -> Docker eval),
# full-precision models over OpenRouter (no GPU). Emits a scored json.
#
# Pipeline (Agentless methodology, cheap variant):
#   get repo structure (cached) -> file-level localize (temp 0)
#     -> related-element localize -> line-level localize
#     -> merge -> repair (temp 0.8, N samples) -> select sample 0
#     -> swebench.harness.run_evaluation (Docker) -> scored json
#
# Localization is LLM-only (no embedding retrieval): OpenRouter has no embeddings
# endpoint, so we feed the LLM file-level result straight into related/line stages.
#
# Usage:
#   scripts/swe_agentless_run.sh <muse|qwen27|qwen35|gemma> [--subset strat50] [--n N] \
#                                [--ids id1,id2,...] [--tag SUFFIX] [--repair-samples K] \
#                                [--workers W]
#
#   # full stratified-50 on muse:
#   scripts/swe_agentless_run.sh muse --subset strat50
#   # first 10 of strat50 on qwen27:
#   scripts/swe_agentless_run.sh qwen27 --subset strat50 --n 10
#   # explicit 2-instance smoke on muse (writes to a -smoke scored dir):
#   scripts/swe_agentless_run.sh muse --ids sympy__sympy-13146,sympy__sympy-13177 --tag smoke
#
set -uo pipefail

REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
AGENTLESS=/home/aliixh/Agentless
DATASET=princeton-nlp/SWE-bench_Lite

KEY="${1:?usage: swe_agentless_run.sh <muse|qwen27|qwen35|gemma> [--subset strat50] [--n N] [--ids id1,id2] [--tag S]}"
shift

SUBSET=""
NLIM=""
IDS_CSV=""
TAG=""
REPAIR_SAMPLES=10       # 10 samples/bug (1 greedy + 9 sampled) = one official Agentless repair run.
                        # Was 1 (a placeholder that crushed SWE scores). Full Agentless = 40 (4 loc-sets x 10);
                        # bump specific models to 40 on OpenRouter for a headline number. Override: --repair-samples N.
EVAL_WORKERS=2
while [ $# -gt 0 ]; do
  case "$1" in
    --subset) SUBSET="$2"; shift 2 ;;
    --n)      NLIM="$2"; shift 2 ;;
    --ids)    IDS_CSV="$2"; shift 2 ;;
    --tag)    TAG="$2"; shift 2 ;;
    --repair-samples) REPAIR_SAMPLES="$2"; shift 2 ;;
    --workers) EVAL_WORKERS="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

# --- model key -> OpenRouter slug + full-precision/reasoning params (extra_body) ---
# temperature is controlled by the Agentless pipeline (localize 0, repair 0.8); the
# per-model reasoning/thinking + top_p/top_k/precision live in extra_body (FRONTIER_SPEC §6).
case "$KEY" in
  muse)   MODEL="meta/muse-glimmer-30b"
          EXTRA='{"top_p":0.95,"top_k":64,"reasoning":{"effort":"xhigh"},"provider":{"order":["Parasail"],"quantizations":["bf16"],"allow_fallbacks":true}}'
          FULLNAME="muse-glimmer-30b" ;;
  qwen27) MODEL="qwen/qwen3.6-27b"
          EXTRA='{"top_p":0.95,"top_k":20,"presence_penalty":0.0,"provider":{"quantizations":["fp8"]}}'
          FULLNAME="qwen3.6-27b" ;;
  qwen35) MODEL="qwen/qwen3.6-35b-a3b"
          EXTRA='{"top_p":0.95,"top_k":20,"min_p":0,"presence_penalty":1.5,"provider":{"quantizations":["fp8"]}}'  # presence 1.5 per models_full.yaml (was 0.0)
          FULLNAME="qwen3.6-35b-a3b" ;;
  gemma)  MODEL="google/gemma-4-31b-it"
          EXTRA='{"top_p":0.95,"top_k":64,"reasoning":{"effort":"high"},"provider":{"quantizations":["bf16"]}}'
          FULLNAME="gemma-4-31b" ;;
  qwen38) MODEL="qwen/qwen3.8-27b"   # now on OpenRouter (fp8); local Q4 server ignores the slug + provider
          EXTRA='{"top_p":0.95,"top_k":20,"presence_penalty":0.0,"provider":{"quantizations":["fp8"]}}'
          FULLNAME="qwen3.8-27b" ;;
  *) echo "unknown model key: $KEY"; exit 2 ;;
esac

# --- resolve instance id list ---
IDS=()
if [ -n "$IDS_CSV" ]; then
  IFS=',' read -r -a IDS <<< "$IDS_CSV"
elif [ "$SUBSET" = "strat50" ]; then
  mapfile -t IDS < "$REPO/configs/swe_lite_strat50.txt"
else
  echo "must pass --subset strat50 or --ids <csv>"; exit 2
fi
# strip blanks
CLEAN=(); for i in "${IDS[@]}"; do [ -n "$i" ] && CLEAN+=("$i"); done; IDS=("${CLEAN[@]}")
if [ -n "$NLIM" ]; then IDS=("${IDS[@]:0:$NLIM}"); fi
N=${#IDS[@]}
[ "$N" -gt 0 ] || { echo "no instance ids resolved"; exit 2; }

# --- environment: point Agentless (OpenAI SDK) at OpenRouter (full) or, for Q4, a local
# llama-server via SWE_API_BASE/SWE_API_KEY (backward-compatible: defaults = OpenRouter) ---
export OPENAI_API_KEY="${SWE_API_KEY:-$(cat "$REPO/.openrouter_key")}"
export OPENAI_BASE_URL="${SWE_API_BASE:-https://openrouter.ai/api/v1}"
export OPENAI_API_BASE="$OPENAI_BASE_URL"
export OPENROUTER_API_KEY="$OPENAI_API_KEY"
export AGENTLESS_OPENAI_EXTRA_BODY="$EXTRA"
export PYTHONPATH="$AGENTLESS"

RUN="${KEY}${TAG:+-$TAG}"
WORK="$REPO/results/swe_agentless/$RUN"
STRUCT="$WORK/structures"
LOC="$WORK/loc"
REP="$WORK/repair"
mkdir -p "$STRUCT" "$LOC" "$REP"
export PROJECT_FILE_LOC="$STRUCT"

SCORED_DIR="$REPO/results/scored/${FULLNAME}-${SWE_PRECISION:-full}${TAG:+-$TAG}"
mkdir -p "$SCORED_DIR"

echo "==== SWE Agentless run: key=$KEY model=$MODEL run=$RUN n=$N ===="
echo "instances: ${IDS[*]}"
echo "extra_body: $EXTRA"
echo "workdir: $WORK"
cd "$AGENTLESS"

PY=python3

# --- 0. cache repo structures once per instance (avoids re-clone every stage) ---
for id in "${IDS[@]}"; do
  if [ ! -s "$STRUCT/$id.json" ]; then
    echo "--- structure: $id"
    $PY - "$id" <<'PYEOF'
import json, sys
from datasets import load_dataset
from get_repo_structure.get_repo_structure import get_project_structure_from_scratch
import os
iid = sys.argv[1]
ds = load_dataset("princeton-nlp/SWE-bench_Lite", split="test")
row = [x for x in ds if x["instance_id"] == iid][0]
d = get_project_structure_from_scratch(row["repo"], row["base_commit"], iid, "playground")
out = os.path.join(os.environ["PROJECT_FILE_LOC"], iid + ".json")
with open(out, "w") as f:
    json.dump(d, f)
print("wrote", out)
PYEOF
  else
    echo "--- structure cached: $id"
  fi
done

# --- 1. file-level localization (LLM, temp 0) ---
for id in "${IDS[@]}"; do
  $PY agentless/fl/localize.py --file_level \
      --output_folder "$LOC/file_level" \
      --model "$MODEL" --backend openai \
      --target_id "$id" --num_threads 1 --skip_existing || echo "  [warn] localize failed for $id (empty/None response) — skipping this instance"
done

[ -f "$LOC/file_level/loc_outputs.jsonl" ] || : > "$LOC/file_level/loc_outputs.jsonl"

# --- 2. related-element localization ---
for id in "${IDS[@]}"; do
  $PY agentless/fl/localize.py --related_level \
      --output_folder "$LOC/related" \
      --model "$MODEL" --backend openai \
      --top_n 3 --compress \
      --start_file "$LOC/file_level/loc_outputs.jsonl" \
      --target_id "$id" --num_threads 1 --skip_existing || echo "  [warn] localize failed for $id (empty/None response) — skipping this instance"
done

[ -f "$LOC/related/loc_outputs.jsonl" ] || : > "$LOC/related/loc_outputs.jsonl"

# --- 3. line-level (edit location) localization ---
for id in "${IDS[@]}"; do
  $PY agentless/fl/localize.py --fine_grain_line_level \
      --output_folder "$LOC/edit_samples" \
      --model "$MODEL" --backend openai \
      --top_n 3 --compress --temperature 0.0 --num_samples 1 \
      --start_file "$LOC/related/loc_outputs.jsonl" \
      --target_id "$id" --num_threads 1 --skip_existing || echo "  [warn] localize failed for $id (empty/None response) — skipping this instance"
done

# --- 3a-fix: Agentless merge() expects found_edit_locs to be a LIST of per-sample dicts
# (it slices [st_id:st_id+1]); this fine_grain build emits a bare dict {file: locs}. Wrap it
# so merge() works. Idempotent (only wraps dicts), runs each pass after the cached fine_grain. ---
$PY - "$LOC/edit_samples/loc_outputs.jsonl" <<'PYEOF'
import json,sys
p=sys.argv[1]; rows=[json.loads(l) for l in open(p)]
ch=0
for r in rows:
    fel=r.get('found_edit_locs')
    if isinstance(fel,dict):
        r['found_edit_locs']=[fel]; ch+=1
open(p,'w').write('\n'.join(json.dumps(r) for r in rows)+'\n')
print(f'[fix] normalized found_edit_locs -> list in {ch}/{len(rows)} rows')
PYEOF

# --- 3b. merge edit-location samples into per-sample loc files ---
$PY agentless/fl/localize.py --merge \
    --output_folder "$LOC/edit_individual" \
    --top_n 3 --num_samples 1 \
    --start_file "$LOC/edit_samples/loc_outputs.jsonl" || exit 1

MERGED="$LOC/edit_individual/loc_merged_0-0_outputs.jsonl"
[ -s "$MERGED" ] || { echo "ERROR: merged loc file empty: $MERGED"; exit 1; }

# --- 4. repair (temp 0.8, K samples; sample 0 is greedy) ---
$PY agentless/repair/repair.py \
    --loc_file "$MERGED" \
    --output_folder "$REP" \
    --model "$MODEL" --backend openai \
    --loc_interval --top_n 3 --context_window 10 \
    --max_samples "$REPAIR_SAMPLES" \
    --cot --diff_format --gen_and_process --num_threads 2 || exit 1

PREDS="$REP/output_0_processed.jsonl"
[ -s "$PREDS" ] || { echo "ERROR: predictions empty: $PREDS"; exit 1; }
echo "predictions: $PREDS"

# --- 5. SWE-bench Docker evaluation ---
RUN_ID="agentless_${RUN}"
REPORT_DIR="$WORK/eval"
mkdir -p "$REPORT_DIR"
$PY -m swebench.harness.run_evaluation \
    --dataset_name "$DATASET" \
    --predictions_path "$PREDS" \
    --run_id "$RUN_ID" \
    --instance_ids "${IDS[@]}" \
    --max_workers "$EVAL_WORKERS" \
    --report_dir "$REPORT_DIR" || echo "WARN: harness returned non-zero (some instances may be unresolved)"

# report file is <model_name_or_path>.<run_id>.json. swebench 3.0.15 writes it to its CWD
# (== $AGENTLESS here, since we cd'd there). Search robustly across likely dirs, newest first.
REPORT=$(ls -t "$AGENTLESS/agentless.$RUN_ID.json" "$REPO/agentless.$RUN_ID.json" \
              "$REPORT_DIR/agentless.$RUN_ID.json" "$AGENTLESS"/agentless.*"$RUN_ID"*.json 2>/dev/null | head -1)
[ -z "$REPORT" ] && REPORT="__MISSING__"
echo "[swe] report resolved to: $REPORT"

# --- 6. normalize -> scored json (or ERROR marker if the eval produced no report) ---
SCORED="$SCORED_DIR/swebench_lite.json"
$PY - "$REPORT" "$SCORED" "$N" <<'PYEOF'
import json, sys, os
report_path, scored_path, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
if not os.path.exists(report_path):
    # DO NOT write a false 0 — the Docker eval crashed/produced no report. Mark errored so the
    # board shows pending (·) and the run can be retried, instead of polluting with a fake 0.
    err = scored_path.replace("swebench_lite.json", "swebench_lite.ERROR")
    os.makedirs(os.path.dirname(scored_path), exist_ok=True)
    open(err, "w").write(f"eval produced no report (path {report_path}); not scoring as 0\n")
    print("ERROR: no report -> wrote", err, "and did NOT write a false-0 scored json")
    sys.exit(3)
with open(report_path) as f:
    rep = json.load(f)
resolved = rep.get("resolved_instances", len(rep.get("resolved_ids", [])))
total = n
detail = {
    "resolved_ids": rep.get("resolved_ids", []),
    "unresolved_ids": rep.get("unresolved_ids", []),
    "error_ids": rep.get("error_ids", []),
    "completed_ids": rep.get("completed_ids", []),
}
score = (resolved / total) if total else 0.0
out = {
    "score": score,
    "metric": "swebench_lite_resolved_pct",
    "n": total,
    "resolved": resolved,
    "detail": detail,
}
with open(scored_path, "w") as f:
    json.dump(out, f, indent=2)
print(json.dumps(out, indent=2))
print("scored ->", scored_path)
PYEOF

echo "==== done: $RUN ===="
