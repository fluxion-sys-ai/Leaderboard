# Edge-Intelligence-Benchmark

An automated, **judge-free** benchmark that measures how *smart* edge-sized LLMs are —
across coding, reasoning, and instruction-following — while also recording the
speed, memory, and speculative-decoding metrics you need to actually deploy them.

Built to feed the [Fluxion Edge Leaderboard](https://fluxion-sys.ai/#leaderboard)
(model × hardware × capability). Output is one self-contained, interactive HTML
leaderboard.

---

## Results

**15 edge models, 16 benchmarks, 7 capability dimensions.** Scores are 0–100;
**Average** is dimension-weighted (benchmarks averaged *within* a dimension, then
dimensions averaged equally, so a dimension with 4 benchmarks doesn't out-vote one
with 1). Ranked best-first.

| Model | Average | Instruction | Reasoning | Coding | Long-context | Writing | Agentic | Factuality |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| qwen2.5-7b-instruct | **65.2** | 70.9 | 40.5 | 42.7 | 73.7 | 81.0 | 82.5 | — |
| granite-4.1-8b | **63.0** | 76.7 | 47.0 | 41.8 | 48.7 | 86.2 | 77.9 | — |
| glm-4-9b-0414 | **62.3** | 74.3 | 39.5 | 46.1 | 41.3 | 85.6 | 87.1 | — |
| gemma-2-9b-it | **58.1** | 64.8 | 38.3 | 35.5 | 42.7 | 84.1 | 83.3 | — |
| qwen3-8b | **57.9** | 76.5 | 52.1 | 47.2 | 0.0 | 86.1 | 85.8 | — |
| mistral-nemo-12b | **55.9** | 63.5 | 35.9 | 34.4 | 39.3 | 85.9 | 76.2 | — |
| gemma-4-e4b | **52.1** | 67.7 | 37.3 | 28.2 | 24.7 | 85.0 | 69.6 | — |
| llama-3.1-8b-instruct | **50.7** | 58.2 | 33.0 | 35.8 | 49.3 | 79.4 | 48.8 | — |
| phi-4-mini-instruct | **50.5** | 46.5 | 35.5 | 32.3 | 39.3 | 70.3 | 78.8 | — |
| ornith-1.0-9b | **47.8** | 47.2 | 36.4 | 49.0 | 0.7 | 69.5 | 84.2 | — |
| tess-4-9b | **45.2** | 48.2 | 34.9 | 31.9 | 3.3 | 80.4 | 72.5 | — |
| deepseek-r1-distill-qwen-7b | **41.8** | 45.3 | 40.4 | 35.2 | 0.7 | 61.0 | 68.3 | — |
| llama-3.2-3b | **40.4** | 56.1 | 31.2 | 30.9 | 28.7 | 74.2 | 21.7 | — |
| lfm2.5-8b-a1b | **39.9** | 44.0 | 31.8 | 35.0 | 0.7 | 76.9 | 50.8 | — |
| llama-xlam-2-8b-fc | **39.4** | 31.5 | 22.6 | 25.3 | 35.3 | 44.8 | 76.7 | — |

*Run in progress — **PinchBench** (multi-turn agent) is landing on the top models
and **Factuality** (SimpleQA) is being judged, so the Agentic column will rise and
Factuality will fill in. A few Long-context `0.0`s are RULER edge cases under review.
The interactive version with per-category splits, confidence intervals, and deploy
metrics is [`leaderboard.html`](leaderboard.html).*

---

## Why this exists

Most LLM benchmarks target frontier models and one number ("how smart"). Edge
deployment needs something different:

- **Which model, for which task** — a 3B can tie an 8B on instruction-following yet
  collapse on code reasoning. One score hides that; a per-dimension board shows it.
- **Smart *and* cheap/fast** — an edge model is only useful if it runs. Every score
  sits next to decode speed, time-to-first-token, and memory.
- **Trustworthy numbers** — judge-free scoring (no LLM grader), contamination-resistant
  datasets, and a recorded reason for every failure so a low score is explainable,
  not mysterious.

---

## What it measures

**15 usable models × 16 benchmarks across 7 dimensions.** Every model runs every
benchmark. (19 models were pulled; 4 were excluded for running broken on this
llama.cpp build — below-random output or an unsupported architecture.)

### Models (quantized Q4_K_M GGUF, run on llama.cpp)

| Model | Size | Family | Category |
|---|---|---|---|
| llama-3.2-3b | 3B | Llama | floor |
| phi-4-mini-instruct | 3.8B | Phi | floor |
| gemma-4-e4b | ~4B | Gemma | **2026 flagship** |
| qwen2.5-7b-instruct | 7B | Qwen | anchor |
| deepseek-r1-distill-qwen-7b | 7B | DeepSeek-distill | reasoning (long CoT) |
| llama-xlam-2-8b-fc | 8B | xLAM (Salesforce) | **function-calling specialist** |
| lfm2.5-8b-a1b | 8B-A1B | LFM (LiquidAI) | **2026 MoE (~1B active)** |
| qwen3-8b | 8B | Qwen | **2026, thinking mode** |
| llama-3.1-8b-instruct | 8B | Llama | baseline |
| granite-4.1-8b | 8B | Granite (IBM) | **2026, new family** |
| gemma-2-9b-it | 9B | Gemma | heavyweight |
| glm-4-9b-0414 | 9B | GLM (THUDM) | **2026, new family** |
| ornith-1.0-9b | 9B | Ornith | 2026 |
| tess-4-9b | 9B | Tess (fine-tune) | instruction fine-tune |
| mistral-nemo-12b | 12B | Mistral | long-context |

*Excluded (ran broken on this llama.cpp build): gemma-4-12b, nanbeige4.2-3b,
qwen3.5-4b, qwen3.5-9b.*

### Benchmarks (grouped into 7 capability dimensions)

| Dimension | Benchmark | What it tests | Scoring |
|---|---|---|---|
| **Instruction-Following** | IFEval | verifiable constraints (format/length/keywords) | programmatic constraint checks |
| | JSONSchemaBench | emit JSON valid against a schema | schema validation |
| **Reasoning** | GSM8K | grade-school math (easy) | exact-match |
| | AIME 2026 | olympiad math (hard, fresh) | exact-match (`\boxed{}`) |
| | MMLU-Pro | 14-subject knowledge | exact-match (MC) |
| | ZebraLogic | deductive logic-grid puzzles | full-grid exact-match |
| | GPQA Diamond | graduate-level science (Google-proof) | exact-match (MC) |
| **Coding** | LiveCodeBench | write code, run vs hidden tests (contamination-free) | pass@1, sandboxed |
| | HumanEval+ | write code (floor) | pass@1, **official evalplus scorer** |
| | CruxEval | predict a function's output (code reasoning) | exact-match |
| **Long-context** | BABILong | find facts hidden in long context (length-scaling) | exact-match |
| | RULER | retrieval/aggregation at 8k context | string-match |
| **Agentic** | BFCL | call the right tool/function for a request | AST / value match |
| | PinchBench-Clawd | single-turn personal tasks (right tool + args) | judge-free tool/arg match |
| | PinchBench | multi-turn agent on real file/tool tasks (**Fluxion's metric**) | task rubric (DeepSeek judge) |
| **Writing** | AlpacaEval | open-ended writing quality | **DeepSeek judge** (1–10) |
| **Factuality** | SimpleQA | short-fact recall + calibration (abstention) | **DeepSeek judge** (correct/incorrect/not-attempted) |

---

## Methodology (the rules that make the numbers trustworthy)

- **Judge-free where it's honest.** 11 of the 16 benchmarks are scored objectively —
  execution, exact-match, or a programmatic validator — with **Wilson confidence
  intervals** on every cell. The 5 that can't be exact-matched (Writing, Factuality,
  and the two PinchBench agent benchmarks) use a DeepSeek judge, kept strictly
  separate from the judge-free grid. Where an official reference scorer exists and
  scoring is hard (e.g. evalplus for HumanEval), it's used instead of an in-repo one.
- **Broken models auto-excluded.** A model scoring below the random floor on a
  multiple-choice benchmark (degenerate output) is aborted and logged, not left to
  waste hours or pollute the board.
- **Contamination-resistant.** LiveCodeBench is date-filtered to problems released
  *after* the models' training; AIME/ZebraLogic use fresh 2026 data. Older static
  benchmarks (GSM8K, HumanEval) are kept as floors, not discriminators.
- **Random, stratified sampling.** A fixed-seed random sample (never a biased
  first-N slice), stratified across a benchmark's sub-categories so each is
  represented. Expanding the sample is **additive** — prior prompts are kept, only
  new ones are generated, never repeated.
- **Edge-honest runtime.** Q4_K_M GGUF on llama.cpp — what actually deploys on edge,
  including the quality hit from quantization. Quant is fixed and reported.
- **Reasoning models get room.** Long-CoT models (DeepSeek-R1-distill, Qwen3-8B) get
  a larger token budget so they aren't truncated before the answer; `<think>` blocks
  are stripped before scoring.
- **Sandboxed code execution.** Generated code runs in an isolated subprocess with
  CPU/heap/file limits and a wall-clock timeout — never on the host unguarded.

### What every cell records

Beyond the headline score:
- **per-category splits** (e.g. MMLU-Pro by subject, IFEval by instruction type)
- **failure breakdown** (wrong answer vs. couldn't-parse vs. schema violation vs. timeout)
- **speed / latency / memory** — prefill & decode tok/s, TTFT, peak VRAM, on-disk size
- **speculative-decoding** — per-position acceptance, τ, accept-rate (when a drafter
  is attached; see the `--spec` pass)
- **reproducibility stamp** — quant, engine, context, temperature, GGUF path, timestamp

---

## Repository layout

```
configs/
  models.yaml         models under test (+ runner, quant, optional draft model)
  benchmarks.yaml     benchmarks, sample sizes, dataset pins, seed
  pinchbench_tasks.txt  the pinned PinchBench task suite
src/
  models/             uniform ModelRunner interface + llama.cpp runner (spec-decode aware)
  benchmarks/         one module per benchmark (load / prompt / score) + registry
  evaluators/         judge-free scorers: IFEval checks, sandboxed code executor
  report/             assembles results into the HTML leaderboard (build_leaderboard.py)
  utils/              config IO, resumable-run cache, random/stratified sampler
  models_fetch.py     resolve + download GGUFs from HuggingFace (confirmed at pull time)
scripts/
  pinchbench_run.sh   run PinchBench (multi-turn agent) against one model's endpoint
  top_models.py       rank models by the dimension-weighted Average
run_benchmark.py      the single orchestrator (judge-free grid)
rescore_all.py        re-score all cells offline from cached generations (no GPU)
score_official.py     official reference scorers where scoring is hard (evalplus/HumanEval)
judge_writing.py      DeepSeek judge → Writing scores
judge_simpleqa.py     DeepSeek judge → Factuality scores
import_pinchbench.py  fold PinchBench agent results into the grid
results/
  raw/<model>/<benchmark>.jsonl     model generations (cached — the expensive part; gitignored)
  scored/<model>/<benchmark>.json   metrics (cheap, regenerable)
  spec/                             speculative-decode pass results
leaderboard.html      the interactive output (open in a browser)
CANDIDATES.md         scouted edge models parked for a future run
```

**Design:** every `(model, benchmark)` is its own pair of files, so you can re-run
one cell, resume a crash (a crash costs one cell, not the run), or re-score without
regenerating. Adding a model is a config edit; adding a benchmark is one file + one
registry line.

---

## Usage

```bash
pip install -r requirements.txt
export LLAMACPP_BIN=/path/to/llama.cpp      # directory containing llama-server

# one cell (fast smoke)
python run_benchmark.py --models qwen2.5-7b-instruct --benchmarks ifeval --limit 10

# the full grid (all models × all benchmarks, resumable)
python run_benchmark.py

# speculative-decoding pass — per-position acceptance for models with a draft model
python run_benchmark.py --spec

# re-score everything offline (no GPU), then rebuild the board
python rescore_all.py
python -m src.report.build_leaderboard
```

Results land in `results/`; open `leaderboard.html`.

---

## The leaderboard

Ranked by **Average** (dimension-weighted mean of the capability scores, 0–100),
with every dimension heat-mapped and grouped by type. Alongside sit the deploy metrics — prefill/decode
tok/s, TTFT, VRAM, size — plus placeholders for the device-specific columns
(battery, hardware cost) that Fluxion fills per physical device. Click any row to
expand its per-category splits, failure reasons, and per-position acceptance.

> No blended "overall score": Fluxion's own blend weights aren't published and two
> of its inputs (price, battery) are device-specific, so we rank on capability and
> show speed/cost separately rather than invent a formula.

---

## The judge-based dimensions (Writing, Factuality, Agentic)

Some capabilities can't be exact-matched, so they're scored by a **DeepSeek judge
(via OpenRouter)** — generated in the normal grid, then judged separately so the
judge-free cells stay untouched:
- `python judge_writing.py` — rates each response 1–10 → mean / 10.
- `python judge_simpleqa.py` — grades Factuality as correct / incorrect / not-attempted.
- **PinchBench** runs the model as a real multi-turn OpenClaw agent (files + tools);
  the judge scores the task rubric. This is the axis that feeds Fluxion's Agent score.

Swap the judge and re-run to re-score cached responses (no regeneration).

## Roadmap

- **LiveBench** — adopt the contamination-free, self-refreshing 7-category suite
- **BFCL v4** — re-run agentic tool-use on the current harness version
- **Tests** — unit coverage for the scorers + sandboxed executor
- **v2 writing tasks** — expand Writing beyond a single open-ended set
