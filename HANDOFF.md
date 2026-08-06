# HANDOFF — Edge Intelligence Benchmark (successor Claude: read this FIRST)

You are taking over an edge-model LLM benchmark with **no memory of the prior conversation**. This doc
+ `MIGRATION.md` + the memory bundle are everything you need. Read this top to bottom before touching anything.

## Who you're working for
**shujun** — Pacific time (**always give times in PT**, PDT=UTC−7). Direct, wants *completeness and honesty*,
**hates wasted GPU time** and being surprised by settings. Standing rule you MUST follow: for any tuning
decision, show the **full control panel** (every knob + current value + options + your rec) and help choose —
never dribble knobs out one at a time. (See memory: `be-upfront-about-knobs`.)

## What this project is
A benchmark of ~22 small models (3B–35B, Q4_K_M GGUF) for the **Fluxion Edge Leaderboard**, run on a single
**NVIDIA A100-SXM4-40GB** via **llama.cpp b9892**. Output is a self-contained `leaderboard.html`.
- **Grid** = 15 judge-free academic benches (ifeval, jsonschemabench, gsm8k, aime2026, mmlu_pro, zebralogic,
  gpqa_diamond, livecodebench, humaneval, cruxeval, babilong, ruler, writing[LLM-judge], bfcl, simpleqa[LLM-judge]).
- **PinchBench** = 116-task multi-turn agentic bench, DeepSeek-Chat-v3.1 judge via OpenRouter, run at **128K ctx**.
- **7 dimensions** (each equal-weighted in the avg): Instruction (ifeval+schema), Reasoning (gsm8k/mmlu_pro/
  aime/zebra/gpqa), Coding (livecode/humaneval/cruxeval), Long-context (babilong/ruler), Writing, Agentic
  (bfcl+pinchbench). **SimpleQA is shown but NOT in the average.**

## Hard-won lessons (this is the important part — most bugs are ONE of these)
1. **Empty-output contamination** — reasoning models run WITHOUT direct-answer mode dump `<think>` tokens →
   the extractor strips them → empty output → score ≈ 0. Detect via **empty% on `results/raw/<model>/<bench>.jsonl`**.
   Fix = `no_think: true` in config (Qwen3.x/gemma-4/exaone/ornith/tess support it).
2. **`no_think` is now read FROM config in BOTH grid and pinch** (`pinchbench_run.sh` derives it from models.yaml).
   Don't hardcode per-model lists — that's how models slipped through and needed reruns.
3. **gpt-oss uses harmony** → `reasoning_effort` (low/medium/high), NOT `no_think`. `low` caused empty *final
   channel* on agentic/long tasks (bfcl 60% empty, babilong 43%, pinch 0.05). Rerun those at `medium` (`REASONING_EFFORT=medium`).
4. **max_tokens_mult** — reasoning models with no toggle (lfm2.5) truncate mid-answer at the 1× cap → empty. Bump to 3–4.
5. **Context clamp** — CLI YaRN does NOT work on b9892 (silently clamps to 32k). Use native-128K GGUFs. The
   pinch script has a **clamp-guard** (verifies live `/props` n_ctx ≥ 100k before trusting a run).
6. **128K PinchBench is a HARD RULE** (gemma-2-9b is the only 8K exception). Grid runs at n_ctx 20480.
7. **Solo-GPU** — ONE model/server at a time on the 40GB card. Never run two servers. Orchestration enforces this.
8. **gemma-4-31b fails to load** on b9892 (instant exit — likely arch/MTP, NOT size; e4b/12b of same family load).
   Needs a newer llama.cpp build, probably. Its retry captures the real error.
9. **PinchBench gate** = top-10 by grid avg (skips weak models). BUG we hit: it gated exaone on a *partial* avg
   (before writing was judged) → wrongly skipped. Use `FORCE_PINCH=1` to bypass for a model you definitely want.
10. **Judge drift** — `judge_writing.py`/`judge_simpleqa.py` only judge NEW+complete models (skip-if-scored guard)
    so re-running the sweep doesn't drift already-published LLM-judge scores.
11. **exaone ruler 0.02 is REAL** (degenerate repetition, not a bug) — a genuine long-context weakness. Flagged, kept.

## Current run state (2026-08-06 ~19:23 UTC — will be stale; RE-CHECK live)
Runs are chained solo-GPU via detached waiters in `/tmp/*.sh` (copied to `scripts/orchestration/`). Order:
`stage2 → ornith_rerun → gptoss_medium → qwen_128k_fix (+exaone FORCE pinch) → gemma_last → gemma_e4b → lfm_tess`.
- **12 models good/done.** Currently **ornith pinch** was running. Queue was mid-flight; full finish ~Fri night/Sat PT.
- **Hidden** (see `configs/hidden_models.json`, auto-un-hides when a rerun is <15% empty): qwen3-8b, gemma-4-12b
  (contaminated grids, reruns queued), deepseek-r1-distill (misleading, not fixable — stays hidden).
- Re-derive the live status: `ls /tmp/*.sh` running, `tail /tmp/<name>.log`, `nvidia-smi`, and the empty% sweep.

## How to run (also in MIGRATION.md)
- Grid: `python3 run_benchmark.py --models <name> --benchmarks <15 names>`
- Pinch: `bash scripts/pinchbench_run.sh <name>`  (env: `FORCE_PINCH=1`, `REASONING_EFFORT=medium`)
- **Preflight FIRST** (unproven — smoke-test it once): `python3 scripts/preflight.py <name>` → exit 0 = safe to run.
- Judges (API, no GPU): `python3 judge_writing.py` · `python3 judge_simpleqa.py` · then `python3 rescore_all.py`
- Build site: `python3 -m src.report.build_leaderboard` → `leaderboard.html`
- Publish it: it's live via **GitHub Pages** at https://fluxion-sys-ai.github.io/Leaderboard/ (served from `docs/index.html`
  on `main`, auto-deploys on push). Update loop + visibility notes in **MIGRATION.md → Dashboard hosting**.

## Knobs → `configs/`
`models.yaml` (per-model: gguf/quant, no_think, template_kwargs.reasoning_effort, max_tokens_mult; defaults: n_ctx
20480, temp 0, max_tokens 1024) · `benchmarks.yaml` (sample size, max_tokens) · `score_specs.json` (universal
block + per-score ◆ overrides, shown on the site) · `hidden_models.json` (hidden models + auto-un-hide).

## Open items when you arrive
- Live-smoke-test `scripts/preflight.py` (never validated — GPU was busy).
- gemma-4-31b load error — capture + decide (newer llama.cpp or drop).
- Optional: heartbeat/cron so an AI actually reviews run logs periodically.
- Push to GitHub (`fluxion-sys-ai/Leaderboard`) once creds exist; `results/raw/` is now tracked (backup).
- bfcl leniency for exaone (double-encoded tool calls, mildly understated) — optional.

## Personality note
The prior instance ran in an apologetic-warm, lowercase-casual voice (see `SOUL.md`). Own mistakes fast,
give real evidence and pushback, always times in PT. Be the assistant shujun actually wants to talk to.
