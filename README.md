# Edge-Intelligence-Benchmark

An automated, **judge-free** benchmark that measures how *smart* edge-sized LLMs are —
across coding, reasoning, and instruction-following — while also recording the
speed, memory, and speculative-decoding metrics you need to actually deploy them.

Built to feed the [Fluxion Edge Leaderboard](https://fluxion-sys.ai/#leaderboard)
(model × hardware × capability). Output is one self-contained, interactive HTML
leaderboard.

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

**10 models × 12 benchmarks = 120 cells.** Every model runs every benchmark.

### Models (quantized Q4_K_M GGUF, run on llama.cpp)

| Model | Size | Family | Category |
|---|---|---|---|
| llama-3.2-3b | 3B | Llama | floor |
| phi-4-mini-instruct | 3.8B | Phi | floor |
| gemma-4-e4b | ~4B | Gemma | **2026 flagship** |
| qwen2.5-7b-instruct | 7B | Qwen | anchor |
| deepseek-r1-distill-qwen-7b | 7B | DeepSeek-distill | reasoning (long CoT) |
| qwen3-8b | 8B | Qwen | **2026, thinking mode** |
| llama-3.1-8b-instruct | 8B | Llama | baseline |
| gemma-2-9b-it | 9B | Gemma | heavyweight |
| glm-4-9b-0414 | 9B | GLM (THUDM) | **2026, new family** |
| mistral-nemo-12b | 12B | Mistral | long-context |

### Benchmarks (grouped into 3 capability dimensions)

| Dimension | Benchmark | What it tests | Scoring |
|---|---|---|---|
| **Instruction-Following** | IFEval | verifiable constraints (format/length/keywords) | programmatic constraint checks |
| | JSONSchemaBench | emit JSON valid against a schema | schema validation |
| **Reasoning** | GSM8K | grade-school math (easy) | exact-match |
| | AIME 2026 | olympiad math (hard, fresh) | exact-match (`\boxed{}`) |
| | MMLU-Pro | 14-subject knowledge | exact-match (MC) |
| | ZebraLogic | deductive logic-grid puzzles | full-grid exact-match |
| **Coding** | LiveCodeBench | write code, run vs hidden tests (contamination-free) | pass@1, sandboxed |
| | HumanEval+ | write code (floor) | pass@1, sandboxed |
| | CruxEval | predict a function's output (code reasoning) | exact-match |
| **Long-context** | BABILong | find facts hidden in long context (length-scaling) | exact-match |
| **Agentic** | BFCL | call the right tool/function for a request | AST / value match |
| **Writing** | AlpacaEval | open-ended writing quality | **LLM judge** (1–10) — the one judge-based dim |

---

## Methodology (the rules that make the numbers trustworthy)

- **Judge-free.** Every score is objective — execution, exact-match, or a
  programmatic validator. No LLM grader (that's deferred to a v2 with a judge
  pipeline for writing/factuality).
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
src/
  models/             uniform ModelRunner interface + llama.cpp runner (spec-decode aware)
  benchmarks/         one module per benchmark (load / prompt / score) + registry
  evaluators/         judge-free scorers: IFEval checks, sandboxed code executor
  report/             assembles results into the HTML leaderboard
  utils/              config IO, resumable-run cache, random/stratified sampler
  models_fetch.py     resolve + download GGUFs from HuggingFace (confirmed at pull time)
run_benchmark.py      the single orchestrator
rescore_all.py        re-score all cells offline from cached generations (no GPU)
results/
  raw/<model>/<benchmark>.jsonl     model generations (cached — the expensive part)
  scored/<model>/<benchmark>.json   metrics (cheap, regenerable)
  spec/                             speculative-decode pass results
leaderboard.html      the output
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

Ranked by **Agent** (mean of the capability scores, 0–100), with every dimension
heat-mapped and grouped by type. Alongside sit the deploy metrics — prefill/decode
tok/s, TTFT, VRAM, size — plus placeholders for the device-specific columns
(battery, hardware cost) that Fluxion fills per physical device. Click any row to
expand its per-category splits, failure reasons, and per-position acceptance.

> No blended "overall score": Fluxion's own blend weights aren't published and two
> of its inputs (price, battery) are device-specific, so we rank on capability and
> show speed/cost separately rather than invent a formula.

---

## The one judge-based dimension (Writing)

Writing quality can't be exact-matched, so it's scored by an LLM judge — kept
strictly separate from the judge-free grid:
1. Responses are generated in the normal grid.
2. `python judge_writing.py` loads one judge model and rates each response 1–10
   → score = mean / 10. Swap the judge and re-run to re-score cached responses
   (no regeneration).

## Roadmap

- **Factuality** — SimpleQA (also judge-based; slots next to Writing)
- **LiveBench** — adopt the contamination-free, self-refreshing 7-category suite
- **Tests** — unit coverage for the scorers + sandboxed executor
- *(PinchBench, the agentic file/tool benchmark, lives as its own project — it
  needs real tools + a judge, so it isn't folded into this text-gen board.)*
