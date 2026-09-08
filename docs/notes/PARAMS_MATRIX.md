# PARAMS_MATRIX.md — every benchmark × model × precision, with default/rec params

> Built 2026-08-20 from the live pipeline configs (`models_full.yaml`, `models_q4_frontier.yaml`,
> `scripts/terminalbench_run.sh`, `scripts/swe_agentless_q4_run.sh`) + `RECOMMENDED_PARAMS.md`.
> **Online cross-check status: PENDING** — `web_search` is disabled in this environment, so the
> vendor-source column reflects what `RECOMMENDED_PARAMS.md` cites (HF cards / NVIDIA NIM / Unsloth /
> quantized.fyi, verified 2026-08-11), NOT a fresh live check. Re-verify once a web provider is enabled.

## Scope
- **Priority benchmarks:** PinchBench, TerminalBench (24-task stratified sample), SWE-bench Lite (Agentless).
- **Ignored (per user):** τ³-bank, IFBench, AIME26.
- **Precisions:** `full` = OpenRouter (bf16 where available, else fp8-ceiling) · `q4` = local llama.cpp Q4_K_M.

---

## Base sampling per model (SAME across all benchmarks; only thinking/reasoning toggles)

| Model | temp | top_p | top_k | min_p | presence_pen | precision (full / q4) | source (per RECOMMENDED_PARAMS.md) |
|---|--:|--:|--:|--:|--:|---|---|
| **Muse Glimmer 30B** (Meta) | 1.0 | 0.95 | 64 | — | — | bf16 / Q4_K_XL | HF card + NVIDIA NIM + LM Studio |
| **Gemma-4-31B** (Google) | 1.0 | 0.95 | 64 | — | — | bf16 / Q4_K_M | NVIDIA NIM card + Unsloth + Ollama |
| **Qwen3.6-27B** | 1.0 | 0.95 | 20 | 0 | **0.0** | fp8-ceiling / Q4_K_M | HF Qwen3.6-27B card + Unsloth |
| **Qwen3.6-35B-A3B** | 1.0 | 0.95 | 20 | 0 | **1.5** | fp8-ceiling / Q4_K_M* | HF Qwen3.6-35B-A3B card (Unsloth contests → keep card 1.5) |
| **Qwen3.8-27B** | 1.0 | 0.95 | 20 | 0 | **0.0** | Q4-only** / Q4_K_M | ggml-org repo; recipe inherited from 27B dense (NOT vendor-verified) |

\* Q4 uses `qwen3.5-35b-a3b-q4f` as a stand-in (no 3.6-35B GGUF yet) — flagged on the board.
\** Qwen3.8-27B has no OpenRouter bf16/fp8 yet → Q4-only; the "full" SWE/pinch actually run on the **local Q4 server** (`SWE_API_BASE=127.0.0.1:8081`), so "full" is a mislabel for qwen3.8.

---

## Thinking / reasoning state per (benchmark × model)  ← the part that keeps biting us

**Rule of thumb (user-confirmed 2026-08-20): for the QWEN family, AGENTIC benchmarks run thinking OFF.**
Muse & Gemma keep their reasoning ON (their output parses cleanly; thinking-off would only hurt them).

| Benchmark | Muse Glimmer | Gemma-4-31B | Qwen3.6-27B | Qwen3.6-35B-A3B | Qwen3.8-27B |
|---|---|---|---|---|---|
| **PinchBench** | reasoning **xhigh** (ON) | think **ON** (reasoning:high) | **no_think (OFF)** | **no_think (OFF)** | **no_think (OFF)** |
| **TerminalBench** | reasoning **high** (ON) | think **ON** (reasoning:high) | **thinking OFF** ⟵ corrected | **thinking OFF** ⟵ corrected | **thinking OFF** ⟵ corrected |
| **SWE-Lite (localize)** | n/a (OpenRouter) | n/a | **OFF** (temp-0 fix) | **OFF** | **OFF** (enable_thinking:false + max_tokens 8192) |
| **SWE-Lite (repair)** | temp 0.8 | temp 0.8 | temp 0.8, think **ON** ⚠ | temp 0.8, think **ON** ⚠ | temp 0.8, think **ON** ⚠ |

**How "thinking off" is expressed by backend:**
- **Local Q4 server (llama.cpp):** `chat_template_kwargs {"enable_thinking": false}` — honored natively (verified).
- **OpenRouter:** `enable_thinking:false` is **IGNORED**; must use `reasoning:{"enabled": false}` (verified 2026-08-20).
- Required harness fix: `terminal_bench/llms/lite_llm.py` deep-merges `extra_body` so injected params survive
  terminus's own `extra_body` (was a shallow `{**_extra, **kwargs}` clobber).

---

## ⚠️ Known conflicts / corrections (what to re-verify online)
1. **TerminalBench thinking for Qwen = OFF** (user directive + empirical: thinking-on gave qwen3.8 94 parse-fails
   → 14/24 `agent_timeout`). `RECOMMENDED_PARAMS.md` §B maps Terminal→"thinking-general (ON)", but that doc *admits*
   the per-benchmark thinking assignment is an unverified mapping, not vendor-stated. **CORRECTED to OFF for Qwen.**
2. **SWE repair still runs thinking-ON (temp 0.8)** — suspected cause of muse/qwen27/qwen35 SWE understated/zero
   (few patches produced). If the "thinking off for agentic" default extends to repair, this needs the same fix.
3. **Qwen3.8-27B params are inherited, not vendor-verified** — no official Qwen3.8 card was cross-checked; params
   copied from Qwen3.6-27B dense (presence 0.0). Verify against the real card when online.
4. **35B-A3B presence_penalty 1.5** is card-stated but Unsloth-contested (says 0.0). Kept 1.5.
5. `agent_timeout` = the benchmarked model's terminus-2 agent exceeding the task's standard **360s** wall-clock
   (`max_agent_timeout_sec` in every task.yaml) — a proper, equal-for-all benchmark param, not a harness bug.

---

## TODO when web is enabled
- [ ] Re-verify each model's card params live (temp/top_p/top_k/min_p/presence + thinking default).
- [ ] Confirm Qwen3.8-27B's own recommended recipe (currently inherited from 3.6-27B).
- [ ] Confirm whether "thinking off" is the vendor default for Qwen on ALL agentic benches (pinch/terminal/swe).
