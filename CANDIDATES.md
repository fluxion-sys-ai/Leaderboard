# Candidate models — scouted, worth testing, not (yet) in the matrix

A backlog of edge-tier models found while scouting recent HuggingFace releases.
These are **deferred, not rejected** — each is a credible general-purpose edge model
with a verified GGUF. Promote one by copying it into `configs/models.yaml` (the
follow-up runner is cache-aware, so it only generates the newly-added model).

Verify the Q4_K_M GGUF still resolves at promote time (never assume from memory).

| Model | Size / arch | Repo (GGUF) | Why interesting | Notes |
|-------|-------------|-------------|-----------------|-------|
| **ibm-granite/granite-4.1-3b** | 3.4B dense (Granite) | `ibm-granite/granite-4.1-3b-GGUF` | Same family as the added granite-4.1-8b; strong small-tier, 404k dl, Apache-2.0, safe arch | Cleanest 3B candidate; sibling of the 8B we added |

## Parked for a different track (not the text grid)
- **microsoft/Fara1.5-9B / 4B**, **ByteDance UI-TARS-1.5-7B** — GUI / computer-use agents
  (screenshot-in, action-out). Need a separate GUI-agent benchmark (OSWorld / ScreenSpot),
  not the text-in/text-out grid.

## Rejected while scouting (for the record)
- Too big for edge: Inkling (952B), Laguna-S (117B), Hy3 (299B), MiniMax-M3 (427B),
  Ling-2.6-flash (107B), DeepSeek-V4, GLM-5.x, Kimi-K3.
- Not general chat: Molmo/OlmoEarth (vision/geo), granite-speech (ASR), tipsv2 (vision),
  Dayhoff (protein), skala (DFT), vermeer/magenta (image/media).
- Uncensored merges (capability-degrading): Qwythos-9B, *-Heretic, *-Jbliterated, Ektome-*.

---

# Candidate benchmarks — keep-in-mind list (NOT built, NOT running)

Benchmarks to consider adding, prioritized by which DIMENSION they shore up. The
matrix is heavy on Reasoning (4) / Coding (3) but thin (single-benchmark) on
Long-context, Agentic, and Writing — those are the fragile dimensions to deepen.

| Benchmark | Dimension (gap) | Dataset | Scorer | Cost to add | Notes |
|-----------|-----------------|---------|--------|-------------|-------|
| **BFCL v3 multi-turn** ⭐ | Agentic (thin) | `gorilla-llm/Berkeley-Function-Calling-Leaderboard` (official, 58k dl) or `fireworks-ai/bfcl_v3_multi_turn_base` | `bfcl_eval` (already in scorer-env) | **Medium** — NOT a trivial AST-match like single-turn BFCL; multi-turn is STATEFUL (needs a multi-turn agent loop + simulated tool backend, closer to τ-bench in harness effort). Deepens BFCL from "one call" to "multi-step tool use". | shujun 2026-07-29: add to list, DON'T run yet |
| **BBH** (Big-Bench-Hard) | Reasoning (already deep) | `lukaemon/bbh` (39.7k dl, canonical) or `SaylorTwift/bbh` (Open-LLM version) | lm-eval-harness `bbh` task group (judge-free: exact-match / MCQ, 27 tasks) | **Low** — static dataset, ready scorer in lm-eval-harness | The one CONSENSUS benchmark we're missing (on Open-LLM-v2 + OpenCompass). BUT it's Reasoning, already our heaviest dimension (4 benchmarks) -> adding it matches real boards but does NOT fix a blind-spot. shujun 2026-07-29: add to list, don't run yet |
| RULER | Long-context (thin) | `NVIDIA/RULER`-style | custom, judge-free | Medium | Standard long-context benchmark; more discriminative than BABILong alone |
| **SimpleQA** ⭐ (chosen factuality pick, 2026-07-29) | Factuality (MISSING category) | `google/simpleqa-verified` (cleaned, 3.5k dl) | deepseek grader — classify each answer CORRECT / INCORRECT / NOT_ATTEMPTED (objective classification, not subjective quality; temp 0, reproducible) | Low-Med | The unique signal MMLU-Pro can't give: fact recall **+ calibration** (does it abstain vs hallucinate when unsure?). Cost: becomes the 2nd judge-based benchmark (12 -> 13 benchmarks; 11/13 judge-free). Report both accuracy AND not-attempted rate. shujun 2026-07-29: add to list. Chose SimpleQA over PopQA (judge-free but recall-only, overlaps MMLU-Pro) and TruthfulQA (misconceptions, not recall). |
| τ-bench | Agentic (alt to BFCL-mt) | Sierra tau-bench | final-state match, judge-free | High | The prestige standard (AA uses τ²/τ³); interactive env — biggest harness lift |
| MBPP+ | Coding (already strong) | `evalplus/mbppplus` | evalplus (already installed) | **Very low** | Cheapest possible add; pairs with HumanEval+. Low priority (Coding already deep) |
| MATH-500 | Reasoning/math (already strong) | `HuggingFaceH4/MATH-500` | SymPy + equality-check | Low-Med | Fills mid-tier math (GSM8K easy -> MATH-500 -> AIME hard). Low priority |
| MuSR | Long-context + Reasoning | `TAUR-Lab/MuSR` | judge-free MCQ | Low-Med | Multi-step reasoning over ~1000-word problems (from HF Open-LLM-v2) |

Priority for real blind-spots: (1) an Agentic benchmark [BFCL v3-mt or τ-bench],
(2) RULER for long-context, (3) SimpleQA for the missing Factuality category.

## Agentic candidates — mined from LLM-Agent-Benchmark-List (2026-07-29)
Focused on **personal-task, active, edge-tractable**. Skipped: WebArena/GAIA (too heavy),
CharacterEval (role-play, off-topic), Kinniment/METR (safety-flavored not capability), WFGY (niche).

| Benchmark | Repo | Fit | Note |
|-----------|------|-----|------|
| **Terminal-Bench** ⭐ | `laude-institute/terminal-bench` (2.5k★, active) | 🟢 **strong** — real terminal/CLI personal tasks, judge-free (executes commands). **Artificial Analysis USES THIS in Intelligence Index v4.1.** Medium env lift (sandboxed shell). | The single best personal-task agentic pick outside the Claw family. |
| **AppWorld** | `StonyBrookNLP/appworld` (473★) | 🟡 medium — 9 simulated apps (email, calendar, shopping) + Python API. Rich, but env is a full app-simulator install. | Middleweight; strong personal-task coverage if env justifies. |
| **inspect_evals** (TAC + others) | `UKGovernmentBEIS/inspect_evals` (609★, active) | 🟡 curated | It's a MONOREPO of many evals — grab specific tasks (TAC = travel agent, others). |
| **OdysseyBench** | `microsoft/OdysseyBench` (14★) | 🟡 speculative | Long-horizon office workflows; low traction but Microsoft. |
| **WorfBench** | `zjunlp/WorfBench` (155★, ICLR 2025) | 🟡 workflow-gen | Agentic workflow generation, not task execution — different flavor. |

**Verdict:** If you add ONE more agentic benchmark beyond PinchBench-Clawd + local PinchBench, it
should be **Terminal-Bench** — it's the AA-blessed standard, personal/CLI-task oriented, active.

Decisions (2026-07-29):
- Factuality: chose **SimpleQA** (`google/simpleqa-verified`). See row above.
- Writing: **do NOT add more.** One benchmark (AlpacaEval) is enough — writing is
  judge-based regardless, and it's the least intelligence-correlated dimension.
  Possibly even OVER-weighted; consider down-weighting if we move to dimension-weights.
