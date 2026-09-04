#!/bin/bash
# TerminalBench (agentic terminal tasks) for the Frontier tab, full-precision over OpenRouter.
# Uses the terminus-2 agent (Meta's Muse Glimmer methodology) on the official
# terminal-bench-core==0.1.1 dataset. Each task runs in its own Docker container.
#
# Usage: scripts/terminalbench_run.sh <muse|qwen27|qwen35|gemma> [n_tasks]
#   e.g. scripts/terminalbench_run.sh muse 2      # smoke
#        scripts/terminalbench_run.sh muse        # full dataset
set -u
REPO=/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark
export PATH="$HOME/.local/bin:$PATH"
export OPENROUTER_API_KEY="$(cat "$REPO/.openrouter_key")"
KEY="${1:?usage: terminalbench_run.sh <muse|qwen27|qwen35|gemma> [n_tasks]}"
NTASKS="${2:-}"

# MODEL slug + TB_MODEL_PARAMS = recommended sampling + thinking + precision pin, injected
# into litellm.completion by our lite_llm.py patch (terminus-2 only plumbs temperature, which
# we pass separately via --agent-kwarg temperature=1.0). NO temperature/max_tokens here:
# temperature is set by the agent; max_tokens is left to terminus so long terminal context
# never overflows. Muse & Gemma get reasoning:{effort:high} (else Gemma runs non-thinking).
case "$KEY" in
  muse)   MODEL="openrouter/meta/muse-glimmer-30b"
          # bf16 full-precision via Parasail (DeepInfra's muse endpoint 404s; Parasail is the working bf16
          # provider used by the SWE config). allow_fallbacks:true so a busy Parasail routes to another bf16.
          export TB_MODEL_PARAMS='{"top_p":0.95,"extra_body":{"top_k":64,"reasoning":{"effort":"high"},"provider":{"quantizations":["bf16"],"order":["Parasail","DeepInfra"],"allow_fallbacks":true}}}' ;;
  gemma)  MODEL="openrouter/google/gemma-4-31b-it"
          # CoreWeave first: it honours the reasoning param via litellm (OpenInference serves
          # gemma NON-thinking through litellm — verified 2026-08-13). Both are true bf16.
          export TB_MODEL_PARAMS='{"top_p":0.95,"extra_body":{"top_k":64,"reasoning":{"effort":"high"},"provider":{"quantizations":["bf16"],"order":["CoreWeave","Novita"],"allow_fallbacks":true}}}' ;;
  qwen27) MODEL="openrouter/qwen/qwen3.6-27b"
          export TB_MODEL_PARAMS='{"top_p":0.95,"presence_penalty":0.0,"extra_body":{"top_k":20,"min_p":0,"provider":{"quantizations":["fp8"],"allow_fallbacks":true}}}' ;;
  qwen35) MODEL="openrouter/qwen/qwen3.6-35b-a3b"
          export TB_MODEL_PARAMS='{"top_p":0.95,"presence_penalty":1.5,"extra_body":{"top_k":20,"min_p":0,"provider":{"quantizations":["fp8"],"allow_fallbacks":true}}}' ;;
  qwen38) MODEL="openrouter/qwen/qwen3.8-27b"
          export TB_MODEL_PARAMS='{"top_p":0.95,"presence_penalty":0.0,"extra_body":{"top_k":20,"min_p":0,"provider":{"quantizations":["fp8"],"allow_fallbacks":true}}}' ;;
  claude) MODEL="openrouter/anthropic/claude-sonnet-5"   # frontier reference (API)
          export TB_MODEL_PARAMS='{"top_p":0.95}' ;;
  *) echo "unknown model key: $KEY"; exit 2 ;;
esac

OUT="${TB_OUT:-$REPO/results/terminalbench/$KEY}"   # TB_OUT overrides output dir (e.g. infra-backfill side dir)
# Stratified terminal sample: run the SAME fixed 24-task subset (configs/terminal_sample.txt,
# stratified by difficulty, seed 42) that the Q4 track uses, so full and Q4 share one denominator.
# TB_SAMPLE_FILE overrides it (e.g. the infra-backfill's short list of just-the-errored task-ids).
# Falls back to full-80 (or --n-tasks N) only if the sample file is absent.
SAMPLE_FILE="${TB_SAMPLE_FILE:-$REPO/configs/terminal_sample.txt}"
EXPECT=$(grep -cE "[^[:space:]]" "$SAMPLE_FILE" 2>/dev/null || echo 80); [ "${EXPECT:-0}" -gt 0 ] || EXPECT=80
# stale-run guard: a prior run dir that is INCOMPLETE (<EXPECT) and not owned by a live tb process is
# stale (e.g. a killed partial + leftover tb.lock). tb refuses/misbehaves on a locked/stale run-id
# dir, so the terminal re-run would never reach EXPECT and downstream gates (other-4 pinch) block
# forever. Back it up and clear it. Complete dirs are never touched.
# run-id controls BOTH the output subdir AND tb's docker container names (<task>-1-of-1-<run-id>).
# When a Q4 GPU run and this full run share run-id "$KEY", they build identically-named containers and
# collide (one deletes the other's container -> 404 -> unknown_agent_error). TB_RUNID lets a concurrent
# run take a distinct namespace so the two never collide. Defaults to $KEY (back-compat, solo runs).
RUNID="${TB_RUNID:-$KEY}"
RUNDIR="$OUT/$RUNID"
if [ -d "$RUNDIR" ]; then
  DONE_N=$([ -f "$RUNDIR/results.json" ] && python3 -c "import json;d=json.load(open('$RUNDIR/results.json'));print(d.get('n_resolved',0)+d.get('n_unresolved',0))" 2>/dev/null || echo 0)
  if [ "${DONE_N:-0}" -lt "$EXPECT" ] && ! pgrep -f "tb run .*terminalbench/$RUNID" >/dev/null 2>&1; then
    BK="$OUT/_stale_${RUNID}_$(date +%s)"; mv "$RUNDIR" "$BK" 2>/dev/null && echo "[tb-full] cleared stale/incomplete run dir ($DONE_N/$EXPECT) -> $BK"
  fi
fi
mkdir -p "$OUT"
TARGS=()
if [ -s "$SAMPLE_FILE" ]; then
  while IFS= read -r t; do [ -n "$t" ] && TARGS+=(--task-id "$t"); done < "$SAMPLE_FILE"
  echo "[tb-full] using stratified sample: $(( ${#TARGS[@]} / 2 )) tasks"
elif [ -n "$NTASKS" ]; then TARGS=(--n-tasks "$NTASKS"); fi

exec tb run \
  --dataset terminal-bench-core==0.1.1 \
  --agent terminus-2 \
  --agent-kwarg temperature=1.0 \
  --model "$MODEL" \
  "${TARGS[@]}" \
  --output-path "$OUT" \
  --run-id "$RUNID" \
  --n-concurrent 2 \
  --global-timeout-multiplier ${TB_MULT:-1.0} \
  --cleanup
