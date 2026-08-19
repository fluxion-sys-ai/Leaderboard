# PIPELINE_CHECK — the "pipeline check" runbook

**Trigger:** when the user says *"pipeline check"* (or "do a pipeline check", "extensive check", "make sure the workflow will go through"), run this end-to-end. Goal: be as close to certain as possible that the benchmark automation runs to completion with **no wrong numbers, no deadlocks, no premature/late timeouts, no GPU contention**, and everything is committed + deployed.

Repo: `/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark`. Commit as **aliixh `<aliixhuang@gmail.com>`**, explicit paths, **no Claude co-author trailer**. Leave results data + machine-path churn uncommitted.

---

## 0 · Snapshot live state (always first)

- The 7 loops up? `weekend_auto qwen38_q4_seq qwen38_chain q4_agentic_queue swe_full_queue qwen38_full_ifaime` (+ any watchdog). Use the bracket trick: `ps -eo args | grep '[w]eekend_auto.sh'` (never `pgrep -f name` — it self-matches).
- Board heartbeat fresh? `.board_heartbeat` age < 10 min.
- Credits (OpenRouter) and burn rate. Guard kills paid runs < $20.
- GPU: `nvidia-smi` — should be **exactly one** server (Q4 llama-server **or** fp8 vLLM), never two. `nvidia-smi --query-compute-apps`.
- Progress markers: Q4 pinch `grep -cE '/1\.0' logs_pb_q4_qwen38.log`; Muse SWE `wc -l results/swe_agentless/muse/loc/related/loc_outputs.jsonl`.

## 1 · Three parallel audit sub-agents (general-purpose, run concurrently)

Launch all three in one turn; synthesize when they return. Give each the recommended-params table (§3) and the known-failure catalog (§4) as ground truth.

1. **Order / gating / coverage** — read every queue script; produce the execution DAG, every gate + what sets each flag, skip-guards, and a master table of all 5 models × 5 benchmarks × {full, Q4} confirming each intended cell is covered **exactly once**. Flag any `until`/`while` wait with no escape, any flag that can be left unset, any double-coverage.
2. **Timeouts / hangs** — enumerate every timeout (script `timeout`, `--global-agent-timeout-sec`, urlopen, curl, keepalive). Flag any unbounded network/server/git op, any bare `curl .../health` without `--max-time`, keepalive thrash windows, per-slot context vs concurrency math.
3. **Wrong-number traps** — verify each known fix present (§4) and hunt new ones: caught-exception-writes-0, missing completeness gate scoring a partial as final, scored-dir name mismatches, over-broad import filters, truncation scored as answer, max_tokens > server ctx.

## 2 · Live process anomaly hunt (the part agents can miss)

- **Duplicate / rogue processes**: is any script running **twice**, or a stale/old version launched manually outside the chain? (`ps -eo pid,ppid,lstart,args`). Two writers to the same output = corruption.
- **Port/model contamination**: for every running benchmark, confirm the model it *thinks* it's hitting matches what's actually on `:8081`. `curl :8081/v1/models` returns the served path — a "full" run answered by the Q4 GGUF is a silent wrong number. **This is the highest-value manual check.**
- If you must kill a contaminating/rogue process, use **`kill -9`** so its EXIT trap (often `free_gpu`) doesn't tear down the *legit* server.

## 3 · Recommended-params reference (verify every run matches)

| Model | temp | top_p | top_k | min_p | presence | thinking / reasoning | precision |
|---|---|---|---|---|---|---|---|
| Muse Glimmer 30B | 1.0 | 0.95 | 64 | — | — | reasoning **xhigh** (SWE/Pinch), **high** (Terminal) | bf16 → **Parasail** (not DeepInfra) |
| Gemma-4-31B | 1.0 | 0.95 | 64 | — | — | reasoning **high** | bf16 |
| Qwen3.6-27B | 1.0 | 0.95 | 20 | 0 | 0.0 | thinking ON (SWE/Terminal/IF/AIME), **no_think** (Pinch) | fp8 |
| Qwen3.8-27B | 1.0 | 0.95 | 20 | 0 | 0.0 | same as 27B | fp8 (self-hosted vLLM) |
| Qwen3.6-35B-A3B | 1.0 | 0.95 | 20 | 0 | **1.5 general/Pinch/IF/AIME, 0.0 SWE coding** | thinking ON | fp8 |

- **SWE (Agentless):** pipeline controls temp — localize **0**, repair **0.8**, `--num_samples 1`. Per-model `top_p/top_k/presence/precision` ride in `extra_body` (full → OpenRouter `provider` pin; Q4 → inherited to the local llama-server). repair_samples=1 is a methodology choice (single-sample), noted, not a bug.
- **IFBench / AIME:** `max_tokens 81920` (benchmark-level, overrides model default). For the **self-hosted qwen38 vLLM** keep `max_tokens_mult: 1` — `81920 × 2 > --max-model-len 98304` would reject every request → false 0.
- **PinchBench:** always **no_think** (thinking-ON zeroes agentic); DeepSeek-v3.1 judge.

## 4 · Known-failure catalog (each must be fixed; re-verify)

- **.QWEN38_DONE deadlock** — must be set on ANY exit of `qwen38_full_seq` (EXIT trap); gates must also proceed if all qwen38 scripts died without it.
- **Rogue/duplicate process on :8081** — full run answered by Q4 model.
- **qwen35 Q4 SWE dir** — writes `qwen3.6-35b-a3b-q4f`, board reads `qwen3.5-35b-a3b-q4f`; relocate.
- **Q4 SWE / Terminal keepalive** — 3-strike health restart **with reload grace** (no thrash); without it an OOM deflates the score.
- **Bare `curl .../health`** — add `--max-time`; a wedged server defeats the loop bound.
- **DeepInfra empty-output** on Muse — pin Parasail (bf16).
- **IFBENCH_DIR** must be `/home/aliixh/IFBench` (capital) or silent 0.0.
- **Reasoning content=None** — fall back to `reasoning`/`reasoning_content` (openrouter_runner + Agentless model.py).
- **SWE missing report** → write `swebench_lite.ERROR`, never a false 0. No stale `agentless.*.json` reuse.
- **Partial gates** — Terminal hides < 80 tasks; pinch import requires `tm ≥ 115`.
- **Watchdog liveness** — `ps -eo args | grep '[x]name.sh'`, not `pgrep -f name`.

## 5 · Apply fixes safely, then verify + ship

- **Never edit a script that's actively doing work** (bash re-reads by byte offset → corruption). If a fix targets a running file, either defer until it's idle or apply it in a non-running wrapper. **Gated/polling loops** (blocked in `until … sleep`) must be **killed + relaunched** to pick up edits — they're doing no work, so it's safe.
- `bash -n` every edited script before restart.
- Re-verify: 7 loops up, single GPU server, gates blocking cleanly (tail their logs), legit runs untouched and progressing.
- Rebuild board `python3 -m src.report.build_leaderboard && cp leaderboard.html docs/index.html`; commit the **rendered** `docs/index.html` too (the board loop only auto-commits it on a *data* change).
- Commit each fix with an explicit path + descriptive message; push; confirm remote reflects it.

## 6 · Report

Lead with anything **live/corrupting** (kill first), then critical deadlocks, then wrong-number traps, then hardening, then what's verified clean. Be honest about residual gaps (e.g. no process-level auto-respawn) — don't claim certainty you can't back.
