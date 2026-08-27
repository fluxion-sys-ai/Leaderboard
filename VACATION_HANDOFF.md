# Vacation handoff — 2026-08-27

Status snapshot taken before the operator went on vacation. Everything below runs **unattended**:
the cron watchdog + GPU keeper respawn any dead/stalled loop, and the board auto-rebuilds and pushes
to GitHub Pages every ~10 min. Say **"update"** on return for fresh numbers.

Live board: https://fluxion-sys-ai.github.io/Leaderboard/ (Frontier tab is the active work).

---

## Current results (agentic Frontier tab)

**TerminalBench — 2× timeout experiment** (24-task stratified sample, % resolved):

| model | full native → 2× | Q4 native → 2× |
|---|---|---|
| Qwen3.8-27B | 33 → **62** (+29) | 33.3 → **41.7** (+8.4) |
| Muse Glimmer 30B | native only (see note) | 33.3 → **41.7** (+8.4) |
| Qwen3.6-27B | 50 → 50 (flat) | running |
| Qwen3.6-35B-A3B | 42 → 42 (flat) | running |
| Gemma-4-31B | 29 → 29 (flat) | running |

*Takeaway: 2× clearly helps Qwen3.8 (both precisions) and Muse Q4; the others net flat (2× clears
timeouts but the freed runs tend to fail a different way rather than solve).*

**SWE-bench Lite — repro-40 rerank (Q4, strat-51, % resolved):** qwen3.8 **25.5**, qwen3.6-27b
**15.7**, gemma **21.6**, qwen3.5-35b **2.0** (emits prose, not the edit format — a real floor).
Where real reproduction tests were generated, the rerank matched majority-vote (same winners).

---

## Running / queued at handoff (all self-healing)

**Full-precision (OpenRouter, ~$103 credit, $5 floor):**
- `muse2x` — muse full-precision 2× terminal, **running** (Parasail bf16; the old DeepInfra pin 404'd, now fixed).
- Full-precision SWE-Lite (`swe_or_select_all.sh`) — **armed**, fires after muse terminal finishes;
  runs qwen3.8 → muse → qwen27 → gemma with `repair 10 + reproduction 40 + rerank`. qwen3.5-35b is
  excluded (no full repair patches — would need a paid repair regen first).

**Local GPU (Q4, free):**
- `tb_2x_q4_rest.sh` — Q4 2× terminal, **qwen27 running** → qwen35 → gemma (backfills disabled).
- After the Q4 terminal batch: `swe_full_select_all.sh` re-runs the **muse + gemma** Q4 SWE cleanly
  with repair-10/repro-40 (their earlier runs were interrupted; partial data backed up aside).

**Rough ETA (5pm PDT / 00:00 UTC target):** muse full terminal and qwen27 Q4 terminal likely done;
qwen3.8 full SWE borderline; qwen35/gemma Q4 terminal, the rest of full SWE, and the Q4 SWE reruns
finish later in the evening, unattended.

---

## What was done today (2026-08-27)

- Finished the **full-precision 2× terminal** sweep; confirmed 2× helps Qwen3.8 (+29pt), flat for
  others — and **verified they're genuine reruns, not regrades** (per-task run-ids/tokens/solved-sets).
- Confirmed **Q4 2× also helps** (Qwen3.8 & Muse +8.4).
- Fixed **muse's OpenRouter 404** — it was a stale provider pin (`DeepInfra, no-fallback`); repointed
  to **Parasail bf16**. Muse full terminal now runs.
- Diagnosed and cleared a **~2-hour GPU stall** (a `tb` process hung in post-run cleanup) and
  **removed unwanted infra-backfills** from the Q4 driver.
- Found the muse/gemma Q4 SWE repro-40 had been **interrupted** (fell back to old scores); set up
  clean reruns and made the board **withhold stale fallback scores** ("rerun pending").
- Rebuilt the leaderboard: native-vs-2× bar chart, paired **Q4 SWE old-vs-new** chart, cleaner
  NEW/OLD param cards, honest "not run yet" blanks.
- Swapped in the new OpenRouter key.

## What was done this week (08-20 → 08-27)

- **08-20:** Full-precision SWE-Lite baselines (majority-vote); fixed the qwen35 empty-patch bug
  (presence_penalty 1.5 → 0.0); parallelized SWE generation on the GPU.
- **08-21:** All 5 Q4 **PinchBench** complete; qwen35 SWE recovered to 10% (whole-function post-processor).
- **08-23:** **SWE-Lite strat-51 complete for all 5 Q4**; qwen35 Q4 SWE confirmed a genuine 0%.
- **08-24:** **Q4 terminal native-timeout re-run complete (all 5)**; tooltip/timeout labeling; hid incomplete τ³.
- **08-25:** Qwen3.8 & Muse **Q4 terminal full-80 complete**; board polish (Frontier default tab, real benchmark names).
- **08-26:** Q4 SWE majority-vote rescore; started the **2× timeout experiment** (fixed a Docker container-name collision).
- **08-27:** see above.

Arc of the week: finished the core Q4 suite (Pinch, SWE strat-51, terminal native) → ran the **2×
timeout** experiment (full + Q4) → moved SWE to the **repair-10/repro-40** selection → built out the
leaderboard visualizations, fixing pipeline bugs throughout.
