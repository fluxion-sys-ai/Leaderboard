# Edge-Intelligence-Benchmark

An automated benchmark that measures how *smart* edge-sized LLMs are — across
instruction-following, reasoning, coding, long-context, writing, and agentic tool-use —
on **quantized GGUF weights running on llama.cpp**, i.e. how they actually deploy on edge.

A per-model × per-capability edge leaderboard. Output is one self-contained, interactive HTML
leaderboard, published live via GitHub Pages.

### 🔗 Live interactive leaderboard → **https://fluxion-sys-ai.github.io/Leaderboard/**

---

## Results

**17 models on the board, 16 benchmarks, 6 weighted capability dimensions** (+ SimpleQA/Factuality
shown but *not* counted in the Average). Scores are 0–100; **Average** is dimension-weighted —
benchmarks averaged *within* a dimension, then the 6 dimensions averaged equally, so a dimension
with 5 benchmarks doesn't out-vote one with 1. Ranked best-first.

| # | Model | Size | Average |
|--:|---|--:|--:|
| 1 | gemma-4-31b | 31B | **82.3** |
| 2 | qwen3.6-27b | 27B | **78.5** |
| 3 | qwen3.5-35b-a3b | 35B | **75.3** |
| 4 | qwen3.5-9b | 9B | **70.9** |
| 5 | ornith-1.0-9b | 9B | **68.9** |
| 6 | mistral-small-3.2-24b | 24B | **65.5** |
| 7 | glm-4-9b-0414 | 9B | **64.9** |
| 8 | granite-4.1-8b | 8B | **61.5** |
| 9 | qwen2.5-7b-instruct | 7B | **59.9** |
| 10 | exaone-4.5-33b | 33B | **59.9** |
| 11 | gpt-oss-20b | 20B | **59.4** |
| 12 | mistral-nemo-12b | 12B | **59.1** |
| 13 | gemma-2-9b-it | 9B | **56.6** |
| 14 | llama-3.1-8b-instruct | 8B | **53.5** |
| 15 | phi-4-mini-instruct | 3.8B | **52.9** |
| 16 | llama-3.2-3b | 3B | **44.1** |
| 17 | llama-xlam-2-8b-fc | 8B | **40.1** |

*The dashboard auto-refreshes as reruns land. The interactive version — per-dimension splits,
per-score settings on click, heat-maps, light/dark — is [`leaderboard.html`](leaderboard.html),
served at **https://fluxion-sys-ai.github.io/Leaderboard/**.*

**Hidden pending clean reruns** (contaminated grids or unfixable output — auto-reappear when a rerun
comes back <15% empty): `qwen3-8b`, `gemma-4-12b`, `gemma-4-e4b`, `tess-4-9b`, `lfm2.5-8b-a1b`,
`deepseek-r1-distill-qwen-7b`.

---

## Why this exists

Most LLM benchmarks target frontier models and one number ("how smart"). Edge deployment needs
something different:

- **Which model, for which task** — a 9B can top the board while a 33B trails it; one score hides
  that, a per-dimension board shows it.
- **Smart *and* cheap/fast** — an edge model is only useful if it runs. Scores sit next to decode
  speed, TTFT, and memory.
- **Trustworthy numbers** — objective scoring wherever honest, and a **recorded reason for every
  failure** so a low score is explainable (e.g. "empty output from thinking-token stripping",
  "harmony analysis-channel bug", "128K KV OOM"), not mysterious.

---

## What it measures

**16 benchmarks across 7 capability areas** (the Average is weighted over 6 — SimpleQA/Factuality is
shown but excluded). Every model runs every benchmark, on an **NVIDIA A100-SXM4-40GB** via
**llama.cpp b9892**, all at **Q4_K_M**.

### Models (quantized Q4_K_M GGUF)

Spanning **3B → 35B**, floor models to 2026 flagships and the new 20–35B tier:

- **20–35B tier:** gemma-4-31b, qwen3.5-35b-a3b (MoE, ~3B active), qwen3.6-27b, mistral-small-3.2-24b,
  exaone-4.5-33b, gpt-oss-20b (OpenAI open, harmony)
- **7–12B:** qwen3.5-9b, ornith-1.0-9b, glm-4-9b-0414, granite-4.1-8b, qwen2.5-7b-instruct,
  mistral-nemo-12b, gemma-2-9b-it, llama-3.1-8b-instruct, llama-xlam-2-8b-fc (function-calling)
- **floor (≤4B):** phi-4-mini-instruct, llama-3.2-3b

(Models that run broken on this llama.cpp build — unsupported arch or below-random output — are
auto-excluded; contaminated ones are temporarily hidden until a clean rerun.)

### Benchmarks (grouped by capability)

| Dimension (weighted) | Benchmark | Tests | Scoring |
|---|---|---|---|
| **Instruction** | IFEval · JSONSchemaBench | verifiable constraints; schema-valid JSON | programmatic |
| **Reasoning** | GSM8K · AIME 2026 · MMLU-Pro · ZebraLogic · GPQA Diamond | math (easy→olympiad), knowledge, logic, grad science | exact-match |
| **Coding** | LiveCodeBench · HumanEval+ · CruxEval | write code vs hidden tests; output prediction | pass@1 (sandboxed / official evalplus); exact-match |
| **Long-context** | BABILong · RULER | facts in long context; retrieval/aggregation | exact / string-match |
| **Writing** | Writing set | open-ended quality | DeepSeek judge (1–10) |
| **Agentic** | BFCL · PinchBench | function-calling; multi-turn real file/tool agent (the headline agentic metric) | AST/value match; task rubric (DeepSeek judge) |
| *Factuality (shown, not counted)* | SimpleQA | short-fact recall + abstention | DeepSeek judge |

---

## Methodology (the rules that make the numbers trustworthy)

- **Objective where it's honest.** Most benchmarks are scored by execution / exact-match / a
  programmatic validator (Wilson CIs per cell). The few that can't be — Writing, Factuality, and
  PinchBench — use a **DeepSeek judge (via OpenRouter)**, kept strictly separate from the objective
  grid. Where an official reference scorer exists (evalplus for HumanEval+), it's used.
- **Reasoning models run in direct-answer mode.** Dual-mode models (Qwen3.x, EXAONE, Ornith,
  Gemma-4, …) are run with `no_think` (`enable_thinking:false`) — otherwise they dump `<think>`
  tokens that get stripped, leaving empty output and fake-low scores. This is the single most common
  failure mode we corrected. gpt-oss (harmony format) uses `reasoning_effort` instead.
- **Every non-default setting is recorded.** Each score carries its exact per-model settings
  (`no_think`, `reasoning_effort`, `max_tokens_mult`, context), shown on click in the dashboard; a
  ◆ marks any score run under a non-default spec (e.g. exaone PinchBench at 64K because 128K KV OOMs
  the 40 GB card).
- **Bad data never ships silently.** A contaminated model (high empty-output %) is **hidden** from
  the board until a clean rerun (<15% empty) auto-un-hides it, rather than publishing artifact-low
  numbers. Broken-on-load models are auto-excluded.
- **Contamination-resistant.** LiveCodeBench is date-filtered to post-training problems; AIME/Zebra
  use fresh 2026 data. Static benchmarks (GSM8K, HumanEval) are floors, not discriminators.
- **Random, stratified, additive sampling.** Fixed-seed random sample (never a biased first-N),
  stratified across sub-categories; expanding a sample keeps prior prompts and only generates new.
- **Edge-honest runtime.** Q4_K_M GGUF on llama.cpp — including the quantization quality hit. Quant
  is fixed and reported. Grid at 20K context; **PinchBench at 128K**. Sandboxed code execution.

---

## Repository layout

```
configs/
  models.yaml          models + per-model knobs (gguf/quant, no_think, reasoning_effort, max_tokens_mult)
  benchmarks.yaml      benchmarks, sample sizes, dataset pins, seed
  pinchbench_tasks.txt the pinned 116-task PinchBench suite
  score_specs.json     universal run specs + per-score ◆ deviations (shown in the dashboard)
  hidden_models.json   models hidden pending a clean rerun (auto-un-hide when <15% empty)
src/
  models/              uniform runner interface + llama.cpp runner (no_think/reasoning/spec-decode aware)
  benchmarks/          one module per benchmark (load / prompt / score) + registry
  evaluators/          objective scorers: IFEval checks, sandboxed code executor
  report/              build_leaderboard.py → the interactive HTML board
  utils/               config IO, resumable-run cache, stratified sampler
  models_fetch.py      resolve + download GGUFs from HuggingFace (confirmed at pull time)
scripts/
  pinchbench_run.sh    run PinchBench against one model (128K; env: FORCE_PINCH, REASONING_EFFORT, PINCH_CTX)
  preflight.py         smoke-test a model's config (load/context/empty/degenerate) BEFORE a full run
  orchestration/       detached solo-GPU "waiter" scripts for unattended runs (+ README, archive/)
run_benchmark.py       the grid orchestrator (objective benchmarks)
rescore_all.py         re-score all cells offline from cached generations (no GPU)
score_official.py      official reference scorers (evalplus/HumanEval+)
judge_writing.py       DeepSeek judge → Writing (skip-guard: only new/complete, no drift)
judge_simpleqa.py      DeepSeek judge → Factuality (same skip-guard)
import_pinchbench.py   fold PinchBench agent results into the grid
docs/index.html        the dashboard served by GitHub Pages
results/
  raw/<model>/<bench>.jsonl     model generations (cached — the expensive part)
  scored/<model>/<bench>.json   metrics (cheap, regenerable)
leaderboard.html       the interactive output (open in a browser)
MIGRATION.md           moving to a new GPU: setup, run commands, dashboard hosting
HANDOFF.md             read-me-first for a successor: state, gotchas, open items
```

**Design:** every `(model, benchmark)` is its own pair of files — re-run one cell, resume a crash
(costs one cell, not the run), or re-score without regenerating. Adding a model is a config edit.

---

## Usage

```bash
pip install -r requirements.txt
export LLAMACPP_BIN=/path/to/llama.cpp      # directory containing llama-server (b9892+)
# secrets (gitignored): .hf_token (HF download), .openrouter_key (DeepSeek judge)

# one cell (fast smoke)
python run_benchmark.py --models qwen2.5-7b-instruct --benchmarks ifeval

# a model's full grid
python run_benchmark.py --models gemma-4-31b --benchmarks ifeval jsonschemabench gsm8k aime2026 \
  mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl simpleqa

# PinchBench (multi-turn agent) for one model — 128K, top-10 gate
bash scripts/pinchbench_run.sh gemma-4-31b

# judge passes (API-only, no GPU) + rebuild the board
python judge_writing.py && python judge_simpleqa.py && python import_pinchbench.py
python -m src.report.build_leaderboard      # -> leaderboard.html
```

Full setup for a fresh GPU (deps, llama.cpp, keys, auto-downloaded GGUFs, dashboard hosting) is in
[`MIGRATION.md`](MIGRATION.md).

---

## The leaderboard

Ranked by **Average** (dimension-weighted mean, 0–100), every dimension heat-mapped and grouped.
Three tabs (Benchmarks / Dimensions / Averages), light+dark, click any header to sort, **click any
score to see the exact settings that produced it**. Published live via GitHub Pages (auto-deploys on
push to `docs/index.html`).

> No blended "overall score": blend weights are subjective and two common inputs (price, battery)
> are device-specific, so we rank on capability and show speed/cost separately.

## Frontier reproduction — Muse Glimmer 30B tab

A separate tab reproduces Meta's published **Muse Glimmer 30B** numbers as a **side-by-side
full-precision vs Q4-local** comparison across 5 frontier 30B-class models and 5 benchmarks, all at
**vendor-recommended / default sampling** (not the greedy board's temp-0 reproducibility settings).

**Models:** Muse Glimmer 30B · Qwen3.6-27B · Qwen3.6-35B-A3B · Qwen3.8-27B · Gemma-4-31B

**Precisions**
- **Full** — OpenRouter with a provider precision pin (bf16 Muse/Gemma, fp8 Qwen). Qwen3.8 isn't on
  OpenRouter, so it's **self-hosted fp8 via vLLM** on the local GPU.
- **Q4** — Q4_K_M GGUFs on a local A100 via llama.cpp (Muse needs build **b10433**; the rest b9892).

**Benchmarks (each at its recommended recipe)**

| Benchmark | Recipe |
|---|---|
| IFBench, AIME'26 | direct; thinking ON; `max_tokens` 81,920 |
| PinchBench (116-task multi-turn agent) | **no_think** (thinking-ON zeroes agentic pinch); DeepSeek-chat-v3.1 judge |
| TerminalBench (terminus-2, terminal-bench-core; 24-task stratified sample) | thinking ON; native per-task timeout **and** a 2× global-timeout variant (see *Current experiments*) |
| SWE-bench Lite (Agentless; full strat-20, Q4 strat-51, seed 42) | localize temp 0 / repair temp 0.8; `repair --max_samples 10` + `reproduction-tests --max_samples 40` + reproduction-only rerank (see *Current experiments*) |

Per-model sampling: Muse/Gemma `temp 1.0 / top_p 0.95 / top_k 64`; Qwen `1.0 / 0.95 / 20` + presence
(27B & 3.8 = 0.0, 35B = 1.5; SWE uses the coding recipe → presence 0.0 for all Qwen). Muse/Gemma
reasoning is `high`/`xhigh` (agentic/coding).

**Runner scripts** (`scripts/`): `pinchbench_{full,q4}_run.sh`, `terminalbench_{,q4_}run.sh`,
`swe_agentless_{,q4_}run.sh`. Locally-served agentic models are reached through an **`edgelocal`**
(llama.cpp) or **`vllmfull`** (vLLM fp8) OpenAI-compatible provider registered in `openclaw.json`.

### Current experiments (agentic tab)

Two config sweeps are running on top of the base Frontier grid. Both compare a **new** setting
against the **old** one per model, side-by-side, and *never overwrite* the old number with a
fallback — an interrupted/empty run shows "pending", not a stale score.

**1. TerminalBench — does a 2× per-task timeout help?** Re-run each model with
`--global-timeout-multiplier 2.0` (double the per-task budget) vs the native timeout, on the same
24-task sample. These are genuine independent reruns (distinct run-ids, different token counts and
solved-task sets — verified, not regrades).
- **Full-precision qwen3.8: 33 → 62% (+29pt)** — the clear win; extra time converts near-solves.
- **Q4 qwen3.8 & muse: 33.3 → 41.7% (+8.4)** — 2× also helps the quantized models.
- Other models land ~flat: 2× clears most timeouts but the freed runs often fail a *different* way
  rather than solving, so gains and losses net even.
- Scripts: `tb_2x_full_all.sh` (OpenRouter full-precision, rolling-2, credit-floored),
  `tb_2x_q4_rest.sh` (local-GPU Q4, sequential). **No infra-backfills** — the 2× rerun is kept clean.

**2. SWE-bench Lite — reproduction-test rerank vs majority-vote.** Old selection took a majority
vote over 10 repair samples; the new one adds `generate_reproduction_tests --max_samples 40` and
**reranks patches by which pass a generated reproduction test** (regression step omitted — its
passing-set gen is unreliable on Q4).
- Where the model generates *real* reproduction tests (qwen3.8, qwen3.6-27b), the rerank runs but
  lands at the **same score** as majority-vote — it selects the same winning patches (a real result,
  not a bug). Models that emit no usable tests fall back and are flagged "rerun pending", not scored.
- Scripts: `swe_or_select_all.sh` (OpenRouter full-precision, sequential, waits for the terminal
  lanes), `swe_full_select_all.sh` (local-GPU Q4, after the Q4 terminal runs).

**Unattended automation** — self-healing shell loops saturate the single GPU (sequential) and
OpenRouter (parallel):
- `weekend_auto.sh` — rebuilds + pushes the board every 10 min (hang-proof: `timeout` on every git op,
  stale-lock cleanup, `.board_heartbeat` liveness).
- `q4_agentic_queue.sh` — Q4 **Pinch → SWE → Terminal** for all 5 models (Terminal last: it's the ~9h
  bottleneck and must never block the others).
- `swe_full_queue.sh` — full-precision SWE for the 4 OpenRouter models, in parallel with the GPU.
- `qwen38_q4_seq.sh` / `qwen38_full_seq.sh` chained by `qwen38_chain.sh` — Qwen3.8 priority run (both
  precisions); `qwen38_full_ifaime.sh` runs Qwen3.8-full IFBench/AIME dead-last.
- A **cron watchdog** respawns any dead/stalled loop every 20 min. It checks liveness with
  `ps -eo args | grep '[x]name.sh'` — **not** `pgrep -f name`, which self-matches the checking shell
  and would silently hide dead loops.

## Roadmap

- **Harness fix for harmony models** — read the analysis channel so gpt-oss's agentic isn't understated
- **LiveBench** — adopt the contamination-free, self-refreshing suite
- **Tests** — unit coverage for the scorers + sandboxed executor
