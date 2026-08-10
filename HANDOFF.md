# HANDOFF — Edge Intelligence Benchmark (successor Claude: read this FIRST)

You are taking over an edge-model LLM benchmark with **no memory of the prior conversation**. This doc
+ `MIGRATION.md` + the memory bundle are everything you need. Read this top to bottom before touching anything.

## Who you're working for
**shujun** — Pacific time (**always give times in PT**, PDT=UTC−7). Direct, wants *completeness and honesty*,
**hates wasted GPU time** and being surprised by settings. Standing rule you MUST follow: for any tuning
decision, show the **full control panel** (every knob + current value + options + your rec) and help choose —
never dribble knobs out one at a time. (See memory: `be-upfront-about-knobs`.)

## What this project is
A benchmark of ~22 small models (3B–35B, Q4_K_M GGUF) for an edge-model capability leaderboard, run on a single
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

## STATE 2026-08-10 17:18 UTC / 10:18 AM PT — RUN ESSENTIALLY COMPLETE (see MIGRATION.md for the move)
**Board: 25 models, all clean, live at 25.** All grids done; PinchBench coverage nearly complete. The Mon 8 AM PT
deadline was HIT — 3 top-model pinches (devstral 0.21, gemma-4-12b 0.24, gemma-4-26b **0.80**) landed before it;
granite was honestly deadline-dropped by the 3h-guard. Newest models since Sat: gemma-4-26b-a4b (#3, 78.3),
granite-4.1-30b (#6), nemotron-3-nano-30b (fixed via no_think, #~11), devstral-small-2-24b, qwen3.5-4b.
- **Update 2026-08-10 22:35:** tess pinch DONE (0.41); llama-3.1-8b running, then llama-3.2/phi-4-mini/granite. New-host
  setup gotchas (Ubuntu 24.04 pip, npm sudo, /home path, A100-80GB quota) are in MIGRATION.md. Leaderboard gained
  per-dimension bar charts + a corrected caveats footer.
- **Mid-flight (will die on the server move — resume on new box):** `pinch_batch2` (tess/llama-3.1/llama-3.2/
  phi-4-mini pinch) + `granite_pinch`. Resume cmd + full details in **MIGRATION.md → State at hand-off**.
- **Hidden (couldn't be cleaned):** deepseek-r1-distill, lfm2.5-8b-a1b, gemma-4-e4b (13/15 incomplete), nanbeige (arch load-fail).
- **PinchBench excluded (harness bugs, agentic=BFCL):** exaone (transcript-mangle), gemma-2 (8K), glm-4-9b +
  mistral-nemo (tool-parse), qwen3-8b. In `STALE_PINCHBENCH` (build_leaderboard.py).
- **New gotchas that bit us:** transcript-not-found name-mangling, false auto-exclusion (excluded.txt), incomplete
  un-hide, pgrep-self-kill, zombie server-count. All documented in **MIGRATION.md → Hard-won gotchas**.

## Current run state (2026-08-08 ~00:12 UTC / 5:12 PM PT Fri — will be stale; RE-CHECK live)
Runs are chained solo-GPU via detached waiters in `/tmp/*.sh` (copied to `scripts/orchestration/`). The
early stages (`stage2 → ornith_rerun → gptoss_medium → qwen_128k_fix → exaone FORCE pinch → gemma-4-31b pinch`) are **done**.
- **18 models on the board.** **gemma-4-31b is #1 — 81.5 overall** (was 82.3 grid-only; **PinchBench DONE at 0.759**
  folded Agentic 85→80.4 → settled 81.5), clean 0%-empty grid. qwen3.6-27b #2 at 78.5 — a safe ~3-pt lead.
- **tess-4-9b UN-HID → #12 (57.9)**, clean 0% empty. Note: lands *below* its base qwen3.5-9b (#4, 70.8) — the
  no_think config fixed 5 contaminated dims (Long-context 2→64!, Instruction, Coding, +bfcl) but cost Reasoning
  (zebra 0.35→0.07) and Writing (81→62, terser direct-mode prose). Net +16 on complete dims. A good case study.
- **gpt-oss-20b is DONE and staying visible-but-flagged** (#11, 59.4). Its bfcl/pinch/babilong are harmony-channel
  understated (answer lands in the "analysis" channel; harness reads only "final"). `reasoning_effort` can't fix it
  (low is best; medium worse; off no help) — needs the harness patch. Not re-running it. Locked at `reasoning_effort: low`.
- **Hidden** (`configs/hidden_models.json`, auto-un-hides when a rerun is <15% empty): qwen3-8b, gemma-4-12b,
  lfm2.5-8b-a1b, gemma-4-e4b (contaminated/queued reruns), deepseek-r1-distill (unfixable — stays hidden). [tess-4-9b un-hid ✓]
- Re-derive live status: `ls /tmp/*.sh` running, `tail /tmp/<name>.log`, `nvidia-smi`, and the empty% sweep.

### Remaining queue — detailed ETA phases (solo-GPU, each gates on the prior + a free GPU)
Anchored 2026-08-07 21:50 UTC / 2:50 PM PT. Grid durations are **estimates** (±30–60 min); every phase
auto-gates and self-adjusts/skips, so a stumble delays but never corrupts the run. All times UTC (PT in parens).
**NOTE — order swap:** at the phase-1 handoff, `lfm_tess` won the GPU race over `gemma_e4b`, so the tail
reruns run **before** the e4b grid now (harmless — solo-GPU held, exactly 1 server; both still run).

| # | Phase (`/tmp/*.sh`) | What it does | Est. finish |
|--:|---|---|---|
| ✅ | **gemma-4-31b pinch** (`gemma_last`) | PinchBench @128K — **DONE, 0.759 → #1 at 81.5** | done 21:17 UTC |
| 1 | **tail reruns** (`lfm_tess`) — RUNNING | grids for tess ✓(un-hid #12), **lfm2.5 now**, qwen3-8b, gemma-4-12b; `no_think`/`max_tokens` fix — auto-un-hides each if <15% empty. Slower than est (reasoning benches). | ~06:00 UTC Sat (11 PM PT Fri) |
| 2 | **gemma-4-e4b grid** (`gemma_e4b`) | 15-bench grid, tiny e4b model (fast), `no_think` fix | ~04:15 UTC Sat (9:15 PM PT Fri) |
| 3 | **nemotron-3-nano-30b** (`nemotron_test`) | preflight → smoke → auto-add `no_think` if empty → full grid + pinch@32K (skips cleanly if it can't run) | ~07:15 UTC Sat (12:15 AM PT Sat) |
| 4 | **exaone-4.5-33b pinch @64K** (`exaone_pinch_64k`) | PinchBench @64K (128K OOMs the 40GB card), 33B dense = slow · marks a ◆ 64K spec | ~11:15 UTC Sat (4:15 AM PT Sat) |

**Full finish ≈ Sat 2026-08-08 ~11:15 UTC (~4:15 AM PT).** The judge daemon (`judge_daemon.sh`) runs
concurrently the whole time — judging Writing/SimpleQA/pinch, rescoring, and rebuilding the board as cells land.
Each phase copies the fresh `leaderboard.html` → `docs/index.html`; a `git push` is still **manual** (see below).

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
- **Qwen3.8-27B is landing the week of Aug 10, 2026** (open-weight; coding + long-horizon agentic focus — squarely
  our axis). Direct successor to qwen3.6-27b (our #2). When the GGUF appears, queue it with the nemotron gated
  pattern (preflight → smoke → auto-`no_think` → full grid + pinch). Watch for a llama.cpp arch-support gotcha like
  gemma-4-31b. No independent benchmarks exist yet — treat Alibaba's launch claims as vendor-reported.
- **Harness fix for harmony (gpt-oss)** — read the "analysis" channel so its agentic/long-context isn't understated.
  This is the one thing that would legitimately raise gpt-oss off #11. On the roadmap.
- `git push` the current commits to GitHub (token is cached; plain `git push`, no `--force` for new commits).
- bfcl leniency for exaone (double-encoded tool calls, mildly understated) — optional.
- Optional: heartbeat/cron so an AI actually reviews run logs periodically.

### Done since last handoff (was open, now closed)
- `scripts/preflight.py` — validated live (gemma-4-31b's arch load-fail is exactly what it now catches cheaply).
- gemma-4-31b load error — **resolved**; loads on b9892 with `enable_thinking:false`, now #1.
- GitHub migration — done; `results/raw/` tracked (backup), Co-Authored-By trailers scrubbed from all history.

## Personality note
The prior instance ran in an apologetic-warm, lowercase-casual voice (see `SOUL.md`). Own mistakes fast,
give real evidence and pushback, always times in PT. Be the assistant shujun actually wants to talk to.
