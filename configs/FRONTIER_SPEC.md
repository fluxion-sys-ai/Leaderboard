# FRONTIER_SPEC.md — the definitive per-model × per-benchmark parameter spec

**Single source of truth (2026-08-13) for the Frontier tab** (Muse Glimmer 30B vs Qwen3.6-27B vs
Qwen3.6-35B-A3B vs Gemma-4-31B, **full-precision vs Q4-local**). This supersedes the per-benchmark
matrix in `RECOMMENDED_PARAMS.md` (which wrongly said "IFBench → thinking OFF"). Values here match
`configs/models_full.yaml`, `configs/models_q4_frontier.yaml`, and `configs/benchmarks.yaml` exactly.

## 0. The rule that governs everything
- **Thinking/reasoning is ON for every model on every Frontier benchmark** (IFBench, AIME, τ³).
  These are reasoning models run at their vendor-recommended defaults, which is thinking-ON.
  *Proof it's correct:* Muse at reasoning **xhigh** scored IFBench **77.0 = the published 77.0 exactly.*
- **The greedy board is the opposite** and SEPARATE: it runs these same weights at **temp 0.0 + no_think**
  for reproducibility. Never confuse the two. The Frontier tab must never inherit greedy/no_think.
- **max output tokens = 81,920** (max-recommended, Qwen competition-math ceiling) for IFBench + AIME.

## 1. THE THINKING TRIGGER DIFFERS BY MODEL × PRECISION — this is the gotcha that cost the bad gemma runs
Enabling thinking is **not one switch**. Each model/precision needs a different mechanism, and you MUST
smoke-verify it engaged (mean output tokens jump from hundreds → thousands) before trusting a run:

| Model | Full-precision (OpenRouter) trigger | Q4-local (llama.cpp) trigger |
|---|---|---|
| **Muse Glimmer** | `reasoning_strength: xhigh` → injected as system-prompt line `Reasoning strength: xhigh` | *(Q4 BLOCKED — llama.cpp lacks the arch)* |
| **Gemma-4-31B** | `extra_body.reasoning: {effort: high}` ⚠️ `chat_template_kwargs` is **IGNORED** by these providers | `template_kwargs: {enable_thinking: true}` |
| **Qwen3.6-27B** | **default-ON** (Qwen chat template thinks by default — no trigger needed) | `template_kwargs: {enable_thinking: true}` |
| **Qwen3.6-35B-A3B** | **default-ON** | `template_kwargs: {enable_thinking: true}` |

> The gemma-full bug: the config had no working trigger, so the provider served it **non-thinking**
> (253 tok/task) → IFBench 47 / AIME 73.3, both invalid. Fix = `reasoning: {effort: high}` (verified
> 2026-08-13: engaged a 5.3k-char reasoning trace). Lesson: **verify thinking per model, never assume.**

## 2. Per-model sampling (identical across IFBench / AIME / τ³ — sampling is a model property, not a benchmark one)

| Model | temp | top_p | top_k | min_p | presence_penalty | Notes |
|---|--:|--:|--:|--:|--:|---|
| **Muse Glimmer 30B** | 1.0 | 0.95 | 64 | — | — | reasoning strength xhigh |
| **Gemma-4-31B** | 1.0 | 0.95 | 64 | — | — | thinking on (see §1) |
| **Qwen3.6-27B** | 1.0 | 0.95 | 20 | 0 | **0.0** | never greedy in thinking mode |
| **Qwen3.6-35B-A3B** | 1.0 | 0.95 | 20 | 0 | **1.5** | ONLY diff vs 27B = presence 1.5 (per its HF card) |

Source: HF model cards (verified 2026-08-11). The 27B (0.0) vs 35B-A3B (1.5) presence_penalty split is
per each model's own card — they are NOT the same recipe.

## 3. Precision / provider pin (full-precision side)
| Model | Precision | Provider pin | Caveat |
|---|---|---|---|
| **Muse** | **bf16** (true full) | DeepInfra only, `allow_fallbacks: false` | DeepInfra hard-caps output at **16,384** → 5 hard AIME tasks truncate (unrecoverable at bf16) |
| **Gemma** | **bf16** (true full) | OpenInference, CoreWeave, Novita (all bf16), fallback ok | providers flaky (503s); NEVER DeepInfra/Chutes (fp4 for gemma) |
| **Qwen27** | **fp8 ceiling** (no bf16 exists) | any fp8, fallback ok | label "fp8, not bf16"; some fp8 providers silently drop `top_k` |
| **Qwen35** | **fp8 ceiling** | any fp8, fallback ok | same top_k caveat |

## 4. Q4-local side (`models_q4_frontier.yaml`)
- Common: `runner: llamacpp · quant: Q4_K_M · n_ctx: 98304 · temperature 1.0 · max_tokens_mult: 2`.
- **n_ctx 98304** (raised from 40960 on 2026-08-13): holds the full 81,920 max-rec output + prompt. Verified it
  loads un-clamped and uses only 22.8/40 GB VRAM. The old 40960 WOULD have truncated qwen Q4 AIME (qwen full AIME
  hit 65k tok); gemma-q4f finished under 14k tok so its 77.7/90.0 are unaffected (no re-run needed).
- Distinct names (`gemma-4-31b-q4f`, `qwen3.6-27b-q4f`, `qwen3.5-35b-a3b-q4f`) so results never collide with the
  greedy board's same-named cells. GGUFs are the greedy board's already-downloaded weights (`gguf.local`, no re-download).
- **Muse Q4 = BLOCKED** (llama.cpp has no muse-glimmer arch). **Qwen35 Q4 uses the 3.5-35B GGUF** (no 3.6-35B GGUF yet).

## 5. Per-benchmark specifics
### IFBench (allenai/IFBench_test, all 300)
- `max_tokens: 81920`. Thinking ON (all). Strict scoring via IFBench's own verifiers.
- Qwen can over-reason past 81,920 on a few tasks → truncation (genuine, at max-rec; not fixable without exceeding rec).

### AIME 2026 (MathArena/aime_2026, all 30)
- `max_tokens: 81920`. Thinking ON (all). Answer = `\boxed{}` in content.
- Muse: 5 tasks truncate at DeepInfra's 16,384 cap (see §3).

### τ³-banking (tau2-bench, banking_knowledge domain) — FULL-PRECISION ONLY
- Agent LLM = the model, at its §2 sampling (temp/top_p/**top_k**/**min_p**/presence) + **thinking** (Muse & Gemma
  get `extra_body.reasoning:{effort:high}`; Qwen default-on) + **`max_tokens: 32768`**.
- ⚠️ **max_tokens is 32,768 here, NOT 81,920.** τ³ is agentic → general rec (32k), and 81,920 output + the large
  agentic prompt (policy + retrieved KB docs + history) **exceeds the 131,072 context → 400 errors** (learned the
  hard way 2026-08-13). 81,920 is the *competition-math* rec, wrong for an agentic loop.
- Harness DEFAULTS (corrected 2026-08-13): **`--max-steps 100`** (was wrongly 40) · **all 97 tasks** (was wrongly 20)
  · `--max-concurrency 2` (score-neutral) · `--retrieval-config qwen_embeddings` · user-sim `deepseek-chat-v3.1` temp 0.
- **No Q4 τ³** currently (would require pointing the tau2 agent at the local llama-server).

### PinchBench-Clawd (hirundo-io/pinchbench-clawd-single-turn) — full + Q4
- Single-turn agentic tool-calling; `per_type: 5` → **104 tasks/model** (stratified across 23 types).
- Thinking ON, §2 sampling. **max_tokens: benchmarks.yaml says 1024 but that's for the greedy board** — the
  frontier runs floor it to **32,768**: full-precision via the OpenRouter runner's `REASONING_MIN`, Q4 via a matching
  floor added to the llama.cpp runner (only when `enable_thinking` — greedy board untouched). Answers are short
  (single tool call) so this is just headroom, not forced long generation.

## 6. PARKED — SWE-bench Lite & TerminalBench (params for when wired; NOT running)
| Benchmark | Muse | Gemma | Qwen (both) |
|---|---|---|---|
| **SWE-bench Lite** (agentic coding · 300 tasks) | reasoning **xhigh** | think ON, temp 1.0 (community 1.5 for code — off-rec, skip) | thinking-**coding**: temp **0.6**, top_p 0.95, top_k 20, presence 0.0 |
| **TerminalBench** (agentic) | reasoning **high** | think ON, temp 1.0 | thinking-general: temp 1.0 (as §2) |
- SWE = Agentless pipeline (localize→repair→validate) + Docker on **SWE-bench Lite** (`princeton-nlp/SWE-bench_Lite`, 300 tasks — chosen over Verified/full: lighter, tractable for 30B); TerminalBench = `terminus-2` agent + Docker,
  dataset `terminal-bench-core==0.1.1`.
- ⚠️ **TerminalBench param limitation:** the `terminus-2` agent only plumbs **`temperature`** to the model (set to
  `1.0` via `--agent-kwarg`, its default is 0.7). It does **NOT** forward top_p/top_k/min_p/presence or a reasoning
  trigger — so **Gemma runs non-thinking** unless we patch terminus-2's LiteLLM wrapper. OPEN DECISION: patch it for
  full rec params, or accept terminus-2's agent defaults as the "standard" agentic-scaffold setup. TerminalBench is
  PAUSED pending this call. SWE-bench not wired yet.

## 7. Published targets (Meta Muse Glimmer card) — for validation
| Benchmark | Muse | Qwen3.6-27B | Gemma-4-31B |
|---|--:|--:|--:|
| **IFBench** | 77.0 | 76.0 | 70.8 |
| **AIME 2026** | 94.7 | 89.2 | 94.1 |
> ⚠️ The card's B/C column order (27B vs Gemma) is ambiguous in the excerpt — **confirm against the actual Meta
> blog before trusting which is which.** Our matches so far: Muse IFBench **77.0 = 77.0 ✓**; gemma Q4 AIME 90.0.
