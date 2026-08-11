# NEW_BENCHMARKS.md — benchmark expansion picks (from Meta Muse Glimmer's eval categories)

Source: **Muse Glimmer 30B model card** (Meta, 2026-08-10, HF `meta-models/Muse-Glimmer-30B`). ⚠️ vendor-reported.
Meta evaluates in **5 categories**. Below: what we already cover, and **2 recommended additions per category** — chosen
from the benchmarks we DON'T have, favoring standard/respected + discriminating-for-30B. Feasibility flagged honestly.

> Meta's headline: Muse Glimmer-30B (high reasoning) vs Gemma4-31B (thinking) vs Qwen3.6-27B (thinking).

---

## Category 1 — General Capabilities & Reasoning
**We have:** AIME 2026 ✓, GPQA Diamond ✓ (also IFEval, MMLU-Pro, ZebraLogic, GSM8K).
**Meta's set:** IFBench, AIME 2026, GPQA Diamond, HLE Text, AA-LCR, Beam128K.
**➕ 2 picks to add:**
1. **IFBench** — instruction-following, successor to IFEval (verifiable constraints). *Feasible* (IFEval-style checker). Muse 77.0 / Gemma 76.0 / Qwen 70.8.
2. **AA-LCR** (Artificial Analysis Long-Context Reasoning) — reasoning *over* long context (beyond retrieval). *Moderate.* Muse 80.0 / Gemma 68.3 / Qwen 73.3.
*(HLE-Text is the buzzy one but brutal — 30B models bunch at ~22% → low discrimination; skip for now.)*

## Category 2 — Agentic Coding
**We have:** LiveCodeBench, HumanEval+, CruxEval (code gen / reasoning), BFCL (tool-use).
**Meta's set:** SWE-Bench Pro, SWE-Bench Verified, TerminalBench 2.1, SciCode.
**➕ 2 picks to add:**
1. **SWE-Bench Verified** — THE standard real-repo issue-fixing agent bench. *HEAVY* (per-task Docker envs + agent scaffold). Muse 76.0 / Gemma 66.6 / Qwen 77.2.
2. **TerminalBench 2.1** — agentic terminal tasks (with terminus2 scaffold). *HEAVY* (sandboxed terminal harness). Muse 51.7 / Gemma 43.4 / Qwen 60.7.
*(SciCode is the lighter alternative if SWE/Terminal are too much — scientific code, no full-agent scaffold.)*

## Category 3 — General Agentic (end-to-end task completion)
**We have:** PinchBench (116-task multi-turn agent), BFCL (function-calling).
**Meta's set:** MCP-Atlas, DeepSearch QA, τ3-Bench, WildClawBench, GDPVal, Gaia2, SkillsBench, OSWorld-Verified.
**➕ 2 picks to add:**
1. **Gaia2** — the standard general-assistant agentic benchmark (multi-step, tools, real tasks). *HEAVY* (agent harness). Muse 43.3 / Gemma 36.4 / Qwen 40.0.
2. **τ3-Bench** (tau-bench family, e.g. τ3-Banking) — standard tool-agent / customer-workflow bench. *HEAVY.* Muse 23.5 / Gemma 15.1 / Qwen 16.7.
*(OSWorld-Verified is excellent but needs a full desktop VM — heaviest of all; defer.)*

## Category 4 — Multimodal  ⚠️ only applies to multimodal models (Muse Glimmer, Gemma-4; most of our board is text-only)
**We have:** none.
**Meta's set:** Charxiv Reasoning, ScreenSpot Pro, OmniDocBench v1.5, MMMU Pro.
**➕ 2 picks to add:**
1. **MMMU Pro** — the standard multimodal reasoning benchmark. *NEW vision pipeline needed.* Muse 74 / Gemma 73 / Qwen 75.
2. **Charxiv Reasoning** — chart/figure understanding (very agent-relevant: reading dashboards). Muse 78.8 / Gemma 77.7 / Qwen 78.4.
*(Adds a whole image-input path to the harness + only scores the multimodal models — treat as its own sub-track.)*

## Category 5 — Security & Privacy (agentic safety)
**We have:** none.
**Meta's set:** CI Memories, Siren AgentDojo. *(only 2 → both are the picks)*
**➕ 2 picks to add:**
1. **AgentDojo** (Siren) — prompt-injection / attack-resistance for tool agents (Attack-Success-Rate ↓ + Utility). *Moderate-HEAVY* (adversarial agent harness). Muse ASR 28.4 / util 94.2.
2. **CI Memories** — contextual-integrity privacy (does the agent leak memory it shouldn't). Muse violation 26.4 / coverage 64.8.

---

## Suggested implementation priority (feasibility × value)
| Tier | Benchmarks | Why |
|---|---|---|
| **1 — do first (feasible now)** | **IFBench**, **SciCode**, **AA-LCR** | verifiable / code / long-ctx — no heavy agent scaffold; discriminating for 30B |
| **2 — heavy but high-value** | **SWE-Bench Verified**, **TerminalBench 2.1**, **Gaia2** | the marquee agentic benches; need Docker + agent scaffolds (weeks) |
| **3 — new sub-tracks** | **MMMU Pro** + **Charxiv** (multimodal), **AgentDojo** + **CI Memories** (security) | need whole new pipelines (vision / adversarial); niche coverage |
| defer | τ3-Bench, OSWorld-Verified, HLE, SWE-Bench Pro | heaviest or least-discriminating for this tier |

**Note:** all agentic/coding/multimodal benches above need infra we don't have yet (Docker task envs, agent scaffolds,
vision input). This is a real multi-week roadmap, not a config edit. Recommend building **Tier 1 first** (IFBench +
SciCode + AA-LCR — the feasible, discriminating ones), then the heavy agentic set once the 80GB GPU is sorted.
