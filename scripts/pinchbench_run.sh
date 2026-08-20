#!/usr/bin/env bash
# Runs PinchBench (agentic personal-task benchmark) against ONE of our edge models
# via its local llama.cpp OpenAI-compatible endpoint. Uses DeepSeek-Chat-v3.1 via
# OpenRouter as the judge (same key as the writing benchmark). SOLO-GPU SAFE —
# refuses to launch if a llama-server is already running.
#
# Usage: pinchbench_run.sh <model-name-from-models.yaml>
#   e.g. pinchbench_run.sh qwen2.5-7b-instruct
#
# Results go to /home/aliixh/pinchbench-skill/results/edge-<model>-*.json to keep
# them clearly separated from prior gemma/qwen custom runs.
set -euo pipefail
MODEL="${1:?pass a model name from configs/models.yaml}"
shift   # consume the model name so it isn't re-passed to benchmark.py via "$@"
REPO=/home/aliixh/edge-intelligence-benchmark
PB=/home/aliixh/pinchbench-skill
PORT=8081

# ── 6th-best gate (shujun 2026-08-04): PinchBench costs ~2.5h — only run it for contenders.
#    Skip if this model's grid dimension-weighted avg (Agentic=BFCL) is below the board's
#    6th-best. Needs the grid to have run first. Fail-OPEN (run) if anything errors.
GATE=$(python3 - "$MODEL" "$REPO" <<'PYEOF' 2>/dev/null || echo "RUN -1 0"
import json,glob,os,statistics,sys
from itertools import groupby
M,REPO=sys.argv[1],sys.argv[2]
DIMS=[("ifeval","I"),("jsonschemabench","I"),("gsm8k","R"),("mmlu_pro","R"),("aime2026","R"),
("zebralogic","R"),("gpqa_diamond","R"),("livecodebench","C"),("humaneval","C"),("cruxeval","C"),
("babilong","L"),("ruler","L"),("writing","W"),("bfcl","A")]
EXCL={"nanbeige4.2-3b"}
def wavg(m):
    row={}
    for f in glob.glob(f"{REPO}/results/scored/{m}/*.json"):
        try: row[os.path.basename(f)[:-5]]=json.load(open(f)).get("score")
        except Exception: pass
    dm=[]
    for _t,g in groupby(DIMS,key=lambda d:d[1]):
        xs=[row[k] for k,_ in g if row.get(k) is not None]
        if xs: dm.append(statistics.mean(xs))
    return 100*statistics.mean(dm) if dm else None
me=wavg(M)
others=sorted([v for d in glob.glob(f"{REPO}/results/scored/*")
  for v in [wavg(os.path.basename(d))]
  if os.path.basename(d)!=M and os.path.basename(d) not in EXCL and v is not None],reverse=True)
th=others[9] if len(others)>=10 else 0.0
print(f"{'SKIP' if (me is None or me<th) else 'RUN'} {(me if me is not None else -1):.1f} {th:.1f}")
PYEOF
)
DECISION=$(echo "$GATE" | awk '{print $1}'); MYAVG=$(echo "$GATE" | awk '{print $2}'); THRESH=$(echo "$GATE" | awk '{print $3}')
# FORCE_PINCH=1 bypasses the gate — for models shujun explicitly wants regardless of the shifting
# threshold (e.g. exaone, wrongly skipped once on a partial avg).
if [ "${FORCE_PINCH:-}" = "1" ] && [ "$DECISION" = "SKIP" ]; then
  echo "[pb] $MODEL FORCE_PINCH=1 — bypassing gate (grid avg $MYAVG, threshold $THRESH)"; DECISION="RUN"
fi
if [ "$DECISION" = "SKIP" ]; then
  echo "[pb] $MODEL SKIPPED PinchBench — grid avg $MYAVG < 6th-best $THRESH (shujun 6th-best rule)"
  exit 0
fi
echo "[pb] $MODEL gate PASS — grid avg $MYAVG >= 6th-best $THRESH"

# solo-GPU rule: refuse to run alongside the main grid
if pgrep -f 'llama-server.*--port '"$PORT" >/dev/null; then
  echo "!! llama-server already running on port $PORT (main grid still active). Aborting."
  exit 1
fi

# resolve the GGUF path via the existing fetcher, then start a dedicated server
GGUF=$(python3 -c "
import sys, yaml
sys.path.insert(0,'$REPO')
from src.models_fetch import ensure_gguf
m=next(x for x in yaml.safe_load(open('$REPO/configs/models.yaml'))['models'] if x['name']=='$MODEL')
print(ensure_gguf(m['name'], m['gguf']))
")
# PinchBench context: the OpenClaw agent's system prompt + skills alone is ~19K
# tokens, so 20480 (the main-grid default) left almost no room for task files and
# ~76% of tasks failed with "context overflow" — a config artifact, not model
# quality. Give each request 32768 (native for granite/glm/qwen2.5/qwen3/mistral,
# so no rope/yarn degradation); gemma-2-9b-it is 8K-native so cap it there rather
# than force-extend. --parallel 1 = one sequential slot (PinchBench runs one task
# at a time) so the FULL context goes to each request instead of being shared.
# Per-model context. Big multi-turn agent tasks overflow 32K on the models that actually
# engage (qwen2.5/qwen3/granite lost 34-44 of 116 tasks to overflow). Raise to 64K:
# granite-4.1 is 128K-native (clean); qwen2.5/qwen3 are 32K-native so extend with YaRN
# rope-scaling; gemma-2 is 8K-native and can't extend.
CTX=32768; YARN_ARG=""
case "$MODEL" in
  # 128K matches shujun's proven prior PinchBench setup — the overnight run found 64K
  # OVERFLOWED on csv/log tasks ("64k-overflow, not skill — 128k should lift them"), and
  # plain -c 131072 worked (Qwen GGUFs carry their YaRN config). granite is 128K-native.
  granite-4.1-8b)                 CTX=131072 ;;   # 128K-native, no scaling needed
  # Qwen2.5/Qwen3 are 32K-native: llama.cpp CLAMPS n_ctx to 32768 unless YaRN is passed
  # EXPLICITLY (plain -c 131072 silently caps at 32K -> still overflows). factor 4 = 32K->128K.
  # 2026-08-05: swapped to 1M/128K-native GGUFs (YaRN baked in) — plain -c 131072 now loads 128K.
  # The old CLI YaRN (--rope-scaling yarn ...) does NOT take on b9892 (clamps to 32K); removed.
  qwen2.5-7b-instruct|qwen3-8b)   CTX=131072 ;;
  # 27B dense / 35B MoE report context_length=262144 (256K native) in GGUF metadata, so plain
  # -c 131072 needs NO YaRN. 64K was found to OVERFLOW csv/log tasks (compaction thrash -> 0.0s);
  # 128K fits 40GB VRAM comfortably (27B measured ~20GB at 64K, ~28GB projected at 128K). [shujun: 128K]
  qwen3.5-35b-a3b|qwen3.6-27b|qwen3.5-9b)    CTX=131072 ;;   # qwen3.5-9b added 2026-08-05 (256K-native)
  # non-Qwen additions — all ≥128K-native (Mistral/Devstral 128K, gemma-4 128K, gpt-oss 128K),
  # so plain -c 131072, NO YaRN. Set here up front so they never hit the 64K overflow bug.
  mistral-small-3.2-24b|devstral-small-2-24b|gemma-4-31b|gpt-oss-20b) CTX=131072 ;;
  # wave 2: granite/gemma 128K+ native (plain). EXAONE 256K via llama3 rope-scale baked in GGUF
  # -> plain -c 131072 should apply it; the runner's n_ctx>=100k guard catches a clamp.
  granite-4.1-30b|gemma-4-26b-a4b|exaone-4.5-33b) CTX=131072 ;;
  # added to PinchBench (had BFCL but no PinchBench). phi=128K-native; ornith clamps to its
  # own max if <128K (llama.cpp caps, no error) — run at native, don't force YaRN.
  ornith-1.0-9b|phi-4-mini-instruct) CTX=131072 ;;
  # post-deadline pinch wave (2026-08-10): all 128K-native — xlam/llama-3.x are Llama-3.1/3.2 128K,
  # tess is Qwen3.5-9B (256K, plain -c 131072 loads 128K). clamp-guard catches any that don't take.
  llama-xlam-2-8b-fc|tess-4-9b|llama-3.1-8b-instruct|llama-3.2-3b) CTX=131072 ;;
  # tool-parse rerun models — 128K too (nemo 128K-native; glm clamps to its max if lower).
  # NOTE: their low score is tool-parse, NOT context — 128K is for consistency, not the fix.
  mistral-nemo-12b|glm-4-9b-0414) CTX=131072 ;;
  gemma-2-9b-it)                  CTX=8192 ;;
esac
# PINCH_CTX env override — for models whose 128K KV OOMs the 40GB card (exaone-33B dense). Lower
# context shrinks the KV to fit. The clamp-guard only fires for the 128K target, so a smaller CTX
# runs as-is. This is a documented spec deviation (marked ◆ in the leaderboard).
[ -n "${PINCH_CTX:-}" ] && CTX="$PINCH_CTX"
# no-think for Qwen3.5/3.6 thinking models — else the agent burns its budget in <think>
# and truncates (empty turns), same as the judge-free grid. Direct-answer mode is fair
# for these explicitly dual-mode models.
# Derive no_think straight from models.yaml so PinchBench MATCHES the grid automatically — any
# reasoning model configured no_think (qwen3.x, exaone, ornith, gemma-4…) runs direct-answer here
# too, without a per-model hardcoded list (that list is exactly how exaone/qwen3-8b slipped through
# and needed reruns). gpt-oss uses reasoning_effort (EFFORT_ARG), not no_think, so it's unaffected.
NOTHINK_ARG=""
NT=$(python3 -c "import yaml;m=[x for x in yaml.safe_load(open('$REPO/configs/models.yaml'))['models'] if x['name']=='$MODEL'];print('1' if (m and m[0].get('no_think')) else '')" 2>/dev/null)
[ -n "$NT" ] && NOTHINK_ARG='--chat-template-kwargs {"enable_thinking":false}'
# Optional reasoning_effort for harmony models (gpt-oss). Env-driven so a rerun can pin it
# (e.g. REASONING_EFFORT=medium) — the empty-final-channel bug at 'low' understated bfcl/babilong/
# pinch. Empty = the GGUF's default. gpt-oss has no NOTHINK_ARG, so no --chat-template-kwargs clash.
EFFORT_ARG=""
[ -n "${REASONING_EFFORT:-}" ] && EFFORT_ARG="--chat-template-kwargs {\"reasoning_effort\":\"${REASONING_EFFORT}\"}"
# reasoning_off (gpt-oss/harmony) from config — disables analysis channel so the FINAL answer lands
# in message.content (fixes the empty-final that tanked pinch to 0.05). Verified 0% empty.
REASONING_ARG=""
RO=$(python3 -c "import yaml;m=[x for x in yaml.safe_load(open('$REPO/configs/models.yaml'))['models'] if x['name']=='$MODEL'];print('1' if (m and m[0].get('reasoning_off')) else '')" 2>/dev/null)
[ -n "$RO" ] && REASONING_ARG="--reasoning off"
# Optional chat-template override (e.g. CHAT_TEMPLATE=chatglm4). Empty = use the GGUF's.
TPL_ARG=""
[ -n "${CHAT_TEMPLATE:-}" ] && TPL_ARG="--chat-template ${CHAT_TEMPLATE}"
echo "[pb] model=$MODEL gguf=$GGUF ctx=$CTX yarn=${YARN_ARG:-no} template=${CHAT_TEMPLATE:-default}"

# start the llama-server
/home/aliixh/llama.cpp/llama-b9892/llama-server \
  -m "$GGUF" -c "$CTX" --parallel 1 -ngl 999 $YARN_ARG $NOTHINK_ARG $EFFORT_ARG $REASONING_ARG $TPL_ARG --host 127.0.0.1 --port $PORT --no-webui \
  >/tmp/pb_llama_${MODEL}.log 2>&1 &
LP=$!
trap "kill $LP 2>/dev/null || true" EXIT

# wait for /health to come up
for i in $(seq 1 120); do
  if curl -sf --max-time 8 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
  sleep 2
done

# CLAMP-GUARD (2026-08-05): if this model is meant to be 128K but the server clamped it
# (GGUF lacks baked rope-scaling — the qwen2.5/qwen3-8b failure mode), SKIP rather than thrash
# a wrong-context run. Only enforced when CTX is the 128K target; gemma-2 (8K) is exempt.
# Fail-OPEN: if the check can't read n_ctx, proceed normally (never blocks on a flaky read).
if [ "$CTX" -ge 100000 ] 2>/dev/null; then
  NCTX=$(curl -s --max-time 8 "http://127.0.0.1:$PORT/props" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('default_generation_settings',{}).get('n_ctx') or 0)" 2>/dev/null)
  if [ -n "$NCTX" ] && [ "$NCTX" -lt 100000 ] 2>/dev/null; then
    echo "[pb] $MODEL CLAMP DETECTED: server n_ctx=$NCTX < 128K — GGUF didn't load 128K. SKIPPING (needs a native-128K GGUF, like qwen2.5/qwen3-8b)."
    kill "$LP" 2>/dev/null || true
    exit 0
  fi
  echo "[pb] $MODEL clamp-guard OK: n_ctx=$NCTX (>=128K)"
fi

# supply the judge key (deepseek via OpenRouter) — same as our writing judge
export OPENROUTER_API_KEY="$(cat "$REPO/.openrouter_key")"

cd "$PB"
# Pinned 116-task suite (shujun's list). Comma-join the task file into --suite.
SUITE=$(paste -sd, "$REPO/configs/pinchbench_tasks.txt")
# --base-url points at our local endpoint; PinchBench skips OpenRouter validation.
# --judge uses the same key. --model is the tag prefix + our model name.
uv run scripts/benchmark.py \
  --model "openai/edge-$MODEL" \
  --base-url "http://127.0.0.1:$PORT/v1" \
  --judge "openrouter/deepseek/deepseek-chat-v3.1" \
  --suite "$SUITE" \
  "$@"
