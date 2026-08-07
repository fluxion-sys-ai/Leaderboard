# Edge-Intelligence-Benchmark

An automated benchmark that measures how *smart* edge-sized LLMs are — across
instruction-following, reasoning, coding, long-context, writing, and agentic tool-use —
on **quantized GGUF weights running on llama.cpp**, i.e. how they actually deploy on edge.

Built to feed the [Fluxion Edge Leaderboard](https://fluxion-sys.ai/#leaderboard)
(model × hardware × capability). Output is one self-contained, interactive HTML leaderboard,
published live via GitHub Pages.

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

*Live snapshot — a full run is grinding through the remaining PinchBench/grid reruns, so numbers
shift as they land (the dashboard auto-refreshes). The interactive version — per-dimension splits,
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
| **Agentic** | BFCL · PinchBench | function-calling; multi-turn real file/tool agent (**Fluxion's metric**) | AST/value match; task rubric (DeepSeek judge) |
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

> No blended "overall score": Fluxion's blend weights aren't published and two of its inputs (price,
> battery) are device-specific, so we rank on capability and show speed/cost separately.

## Roadmap

- **Harness fix for harmony models** — read the analysis channel so gpt-oss's agentic isn't understated
- **LiveBench** — adopt the contamination-free, self-refreshing suite
- **Tests** — unit coverage for the scorers + sandboxed executor
