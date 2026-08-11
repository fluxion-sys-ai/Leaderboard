# NEW_BENCHMARKS.md — frontier-30B comparison benchmark set (5 categories × 2 each)

Fresh comparison project (**Muse Glimmer 30B · Qwen3.6-27B · Qwen3.6-35B-A3B · Gemma-4-31B**), organized around the
**5 capability categories** Meta uses on the Muse Glimmer card. You already have **4 benchmarks**; each category is
filled to **2** (added 6). Meta's own 3-model scores are shown as **validation targets** (vendor-reported).

> Source: Muse Glimmer 30B model card (Meta, 2026-08-10). ⚠️ vendor numbers — validate at full precision before trusting.

> 🟢 **ACTIVE now (2026-08-11):** building **PinchBench · Gaia2 · MMMU Pro · AgentDojo** first (one per category type;
> PinchBench we already have). Per-model recommended params for these four are in **`RECOMMENDED_PARAMS.md` → ⭐ ACTIVE SET**.
> The rest of the 10 below stay on the roadmap.

| # | Category | Benchmark | Status | Muse Glimmer | Gemma-4-31B | Qwen3.6-27B |
|--:|---|---|---|--:|--:|--:|
| 1 | **Reasoning / General** | **AIME 2026** | ✅ have | 94.7 | 89.2 | 94.1 |
| 2 | | **IFBench** | ✅ have | 77.0 | 76.0 | 70.8 |
| 3 | **Agentic Coding** | **SWE-Bench Verified** | ✅ have | 76.0 | 66.6 | 77.2 |
| 4 | | **TerminalBench 2.1** | ✅ have | 51.7 | 43.4 | 60.7 |
| 5 | **General Agentic** | **Gaia2** | ➕ add | 43.3 | 36.4 | 40.0 |
| 6 | | **τ3-Bench** (τ3-Banking) | ➕ add | 23.5 | 15.1 | 16.7 |
| 7 | **Multimodal** | **MMMU Pro** | ➕ add | 74 | 73 | 75 |
| 8 | | **Charxiv Reasoning** | ➕ add | 78.8 | 77.7 | 78.4 |
| 9 | **Security / Privacy** | **AgentDojo** (Siren) | ➕ add | ASR↓ 28.4 / util 94.2 | 25.6 / 90.8 | 40.3 / 92.7 |
| 10 | | **CI Memories** | ➕ add | viol↓ 26.4 / cov 64.8 | 12.1 / 53.0 | 53.4 / 66.9 |

**= 10 benchmarks, 5 categories, 2 each.**

## Why these 6 additions
- **Gaia2** — the standard general-assistant agentic benchmark (multi-step + tools). **τ3-Bench** — standard tool-agent /
  workflow bench (tau-bench family). *(Chose over OSWorld-Verified, which needs a full desktop VM — heaviest.)*
- **MMMU Pro** — the standard multimodal reasoning bench. **Charxiv Reasoning** — chart/figure reading (agent-relevant).
  ⚠️ Only scores multimodal models (Muse Glimmer, Gemma-4); text-only models N/A.
- **AgentDojo** — prompt-injection / attack-resistance for tool agents. **CI Memories** — contextual-integrity privacy
  (agent leaking memory it shouldn't). *(These are the only 2 in Meta's Security category, so both are the picks.)*

## Feasibility (honest — most need infra we don't have yet)
| Tier | Benchmarks | Note |
|---|---|---|
| **Feasible-ish first** | IFBench | verifiable checker, no agent scaffold |
| **Heavy (Docker + agent scaffold)** | SWE-Bench Verified, TerminalBench 2.1, Gaia2, τ3-Bench | multi-week harness build; also need the A100-80GB for BF16 |
| **New pipelines** | MMMU Pro, Charxiv (vision input) · AgentDojo, CI Memories (adversarial harness) | whole new sub-tracks |

## Run config
Vendor-recommended sampling per model/task (NOT greedy) — see **`RECOMMENDED_PARAMS.md`**. Validate at **full precision
(BF16)** against the target columns above before trusting; BF16 30B ≈ ~60 GB → needs the **A100-80GB**.
