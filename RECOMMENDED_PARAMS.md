# RECOMMENDED_PARAMS.md — vendor sampling params + full-precision validation plan

**Purpose:** for the new **frontier-30B comparison tab** — Muse Glimmer 30B (Meta) vs Qwen3.6-27B vs
Qwen3.6-35B-A3B vs Gemma-4-31B — we run each model at its **vendor-recommended sampling** (NOT the main board's
fixed greedy), and **validate at FULL precision (BF16)** against the vendors' published numbers before trusting.
**Active benchmark set (2026-08-11): PinchBench · Gaia2 · MMMU Pro · AgentDojo** (params matrix directly below).
The AIME/IFBench/SWE/TerminalBench tables lower down are kept as general per-model reference.

> ⚠️ All params below are **vendor/community-reported** (HF cards, NVIDIA NIM, Unsloth docs, 2026-08-11) — treat
> as starting points, not gospel. Sources noted per model.
> ✅ Comparison set (confirmed 2026-08-11): **Muse Glimmer 30B · Qwen3.6-27B · Qwen3.6-35B-A3B · Gemma-4-31B.**
> The "35B" = `qwen3.5-35b-a3b` already on the board (MoE, ~3B active). (No Qwen-31B SKU exists.)

---

## ⭐ ACTIVE SET (2026-08-11): params per benchmark × model — PinchBench · Gaia2 · MMMU Pro · AgentDojo
**Key research finding:** vendors publish params **per MODE** (thinking / instruct / coding), NOT per benchmark. All
four active benchmarks are **agentic/reasoning** tasks → each model uses its **thinking/agentic-mode** set. So the
per-benchmark params are the *same* for a given model across all 4 (only the Muse Glimmer *reasoning-strength* and the
MMMU *vision input* differ). Numbers below are each model's thinking-mode recommendation.

| Benchmark (category) | Muse Glimmer 30B | Gemma-4-31B | Qwen3.6-27B | Qwen3.6-35B-A3B |
|---|---|---|---|---|
| **PinchBench** (multi-turn agentic) | temp 1.0 · top_p 0.95 · top_k 64 · **reasoning=xhigh** | temp 1.0 · top_p 0.95 · top_k 64 · **think ON** | temp 1.0 · top_p 0.95 · top_k 20 · min_p 0 · presence 0 | temp 1.0 · top_p 0.95 · top_k 20 · min_p 0 · presence 1.5 |
| **Gaia2** (general agentic) | 1.0 / 0.95 / 64 · **reasoning=xhigh** | 1.0 / 0.95 / 64 · think ON | 1.0 / 0.95 / 20 (thinking-general) | 1.0 / 0.95 / 20 · presence 1.5 |
| **MMMU Pro** (multimodal reasoning) ⚠️vision | 1.0 / 0.95 / 64 · **reasoning=high** | 1.0 / 0.95 / 64 · think ON | 1.0 / 0.95 / 20 (thinking-general) | 1.0 / 0.95 / 20 · presence 1.5 |
| **AgentDojo** (agentic security) | 1.0 / 0.95 / 64 · **reasoning=high** | 1.0 / 0.95 / 64 · think ON | 1.0 / 0.95 / 20 (thinking-general) | 1.0 / 0.95 / 20 · presence 1.5 |

**Per-benchmark notes:**
- **Muse Glimmer** — ONE sampling set (1.0/0.95/64) everywhere; only the **Reasoning strength** (system prompt
  `Reasoning strength: <high|xhigh>`) changes: **xhigh** for the heaviest agentic (PinchBench, Gaia2), **high** for
  MMMU/AgentDojo. Card says use high/xhigh for coding/agentic/complex.
- **Gemma-4-31B** — one default (1.0/0.95/64) across all four, **thinking ON** (`<|think|>`) since all are reasoning/agentic.
- **Qwen3.6-27B / 35B-A3B** — use **thinking-general** (temp 1.0) for all four. *(Their `coding` variant is temp 0.6 — but
  these are agentic/multimodal, not pure code-gen, so thinking-general applies. 35B-A3B carries presence_penalty 1.5.)*
- **MMMU Pro needs image input** — all 4 models are multimodal, so all can be scored; needs a vision path in the harness.
- ⚠️ Qwen warns **never greedy** in thinking mode → temp must stay ≥0.6. Reproducibility: temp>0 → multi-sample + average.

---

---

## Recommended sampling params — per model, per task category

### Muse Glimmer 30B (Meta Superintelligence Labs) — ONE sampling set, varies *reasoning strength*
- **All tasks:** `temperature 1.0 · top_p 0.95 · top_k 64`
- **Reasoning strength** (set in system prompt: `Reasoning strength: <low|medium|high|xhigh>`):
  use **high / xhigh** for coding, agentic, complex reasoning; low/medium for simple tasks.
- 29.6B dense, multimodal (vision encoder), **131K context**, Apache 2.0. GGUF available (lmstudio-community).
- *Source: HF meta-models/Muse-Glimmer-30B card "Best Practices" + NVIDIA NIM + LM Studio.*

### Gemma-4-31B (Google DeepMind) — ONE default across tasks
- **Default (all tasks):** `temperature 1.0 · top_p 0.95 · top_k 64`
- **Coding (community-tested, NOT official):** `temperature 1.5` — community found 1.5 beats the usual 0.6 for code on Gemma-4
- **Deterministic (if you need it):** `temp 0 · top_p 1 · top_k 1`
- Thinking toggled via `<|think|>` token in the system prompt. **256K context.**
- *Source: NVIDIA NIM gemma-4-31b-it card + Unsloth Gemma-4 docs + quantized.fyi (community coding note).*

### Qwen3.6-27B — DIFFERENT params per mode/task
| Mode / task | temp | top_p | top_k | min_p | presence_penalty |
|---|--:|--:|--:|--:|--:|
| Thinking, general | 1.0 | 0.95 | 20 | 0 | 0 |
| Thinking, precise coding | 0.6 | 0.95 | 20 | 0 | 0 |
| Non-thinking (instruct), general | 0.7 | 0.80 | 20 | 0 | 1.5 |

### Qwen3.6-35B-A3B (the "~35B" MoE)
| Mode / task | temp | top_p | top_k | min_p | presence_penalty |
|---|--:|--:|--:|--:|--:|
| Thinking, general | 1.0 | 0.95 | 20 | 0 | 1.5 |
| Thinking, coding | 0.6 | 0.95 | 20 | 0 | 0 |
*Source: Qwen HF cards via quantized.fyi param table (May 2026). Qwen explicitly warns: **do NOT use greedy (temp 0)** in thinking mode → degradation.*

---

## Which params to use per benchmark (category mapping)
Only **Qwen** truly changes params per task; Muse Glimmer + Gemma use one set (modulated by reasoning-strength / think-toggle).

| Benchmark | Category | Muse Glimmer | Gemma-4-31B | Qwen (27B / 35B-A3B) |
|---|---|---|---|---|
| **AIME 2026** | math (thinking) | 1.0/0.95/64, reasoning=high | 1.0/0.95/64, think ON | 1.0/0.95/20 (thinking-general) |
| **IFBench** | instruction-follow | 1.0/0.95/64, reasoning=low–med | 1.0/0.95/64, think OFF | 0.7/0.80/20, presence 1.5 (non-thinking) |
| **SWE-bench Verified** | agentic coding | 1.0/0.95/64, reasoning=xhigh | 1.0/0.95/64 (try 1.5), think ON | 0.6/0.95/20 (coding-thinking) |
| **TerminalBench 2.1** | agentic | 1.0/0.95/64, reasoning=high | 1.0/0.95/64, think ON | 1.0/0.95/20 (thinking) |

---

## FULL-PRECISION validation plan (the reason for this doc)
**Run BF16 (not Q4) and reproduce the vendors' published numbers to confirm harness + params are correct — THEN continue.**
- **VRAM:** a 30B in BF16 ≈ **~60 GB** → does **NOT** fit a 40GB A100. Needs the **A100-80GB** (the one behind the quota
  request) or CPU/disk offload (slow). This is the gating constraint for full-precision.
- **Step 1 — validate:** run AIME 2026 + IFBench at BF16 with the recommended params; compare to targets below.
  Within a few points → harness + params are sound. Way off → debug params/prompt/harness before trusting anything.
- **Step 2 — continue:** only after validation passes, run the full comparison (add SWE-bench + TerminalBench).

### Published targets — Muse Glimmer card (Meta, vendor-reported)
Columns are Muse Glimmer / [model B] / [model C] (B,C ≈ Qwen3.6-27B & Gemma-4-31B per context):
| Benchmark | Muse Glimmer | B | C |
|---|--:|--:|--:|
| **IFBench** | **77.0** | 76.0 | 70.8 |
| **AIME 2026** | **94.7** | 89.2 | 94.1 |
| GPQA Diamond (AA) | 83.5 | **85.7** | 84.2 |
| HLE Text (AA) | 22.0 | **23.6** | 23.1 |
| AA-LCR | **80.0** | 68.3 | 73.3 |
| Beam128K | **65.1** | 58.2 | 63.0 |
*(SWE-bench Verified / TerminalBench numbers weren't in the card excerpt — pull from the full card / Meta report when building.)*

---

## Caveats (important for the reviewer response too)
- **Reproducibility:** temp>0 is stochastic → single-run scores wobble. For trustworthy numbers, **sample N times and
  average** (pass@k / majority) — that's ~N× the compute. Budget for it.
- **This is a SEPARATE tab**, "run-as-recommended" — do **not** merge into the main greedy leaderboard (greedy stays the
  reproducible, apples-to-apples board; this tab shows peak-per-model at vendor settings).
- **Q4 vs full:** vendor numbers are full-precision; your main board is Q4_K_M. Any Q4-vs-published gap is partly
  quantization, partly params — validating at BF16 first isolates that.
- **SWE-bench Verified + TerminalBench 2.1** are heavy agentic-harness integrations (Docker envs + agent scaffold) not
  yet in this repo — sizeable build; 30B models often bunch near the bottom on SWE-bench.
