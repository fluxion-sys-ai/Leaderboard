# MIGRATION — moving this benchmark to a new GPU

Everything you need is in **this repo** + the **public model weights** (auto-downloaded) + one **sibling
skill repo**. Repo payload is ~82 MB; the ~108 GB of GGUF weights are **not** stored here — they stream
from Hugging Face on first run.

## 📦 State at hand-off (2026-08-10 17:18 UTC / 10:18 AM PT) — READ FIRST
**Board: 25 models, all clean, live at 25.** The full run is essentially DONE — all grids complete, agentic
(BFCL+PinchBench) coverage nearly complete. Everything published is in GitHub (`results/scored` + `results/raw`
are tracked), so **git clone on the new box restores all finished work** — you only resume what's mid-flight.

**Mid-flight when you move** (these detached `/tmp/*.sh` runs will die with the old box — RESUME on the new one):
- `pinch_batch2` — PinchBench for **tess-4-9b (running), llama-3.1-8b, llama-3.2-3b, phi-4-mini** (post-deadline coverage)
- `granite_pinch` — PinchBench for **granite-4.1-30b** (was deadline-dropped; OOM→64K fallback)
- To resume on the new box: `for m in tess-4-9b llama-3.1-8b-instruct llama-3.2-3b phi-4-mini-instruct granite-4.1-30b; do FORCE_PINCH=1 bash scripts/pinchbench_run.sh $m && python3 import_pinchbench.py; done` then rebuild+push. (Check which already landed first — some may have committed before you moved.)
- `overnight_watch` + `judge_daemon` — safety/judge daemons; not needed once runs are done.

**PinchBench exclusions (5, agentic=BFCL-only, DON'T re-run expecting a fix — they're harness bugs):**
exaone-4.5-33b (transcript name-mangling), gemma-2-9b-it (8K overflow), glm-4-9b-0414 + mistral-nemo-12b
(tool-parse), qwen3-8b (stale). Listed in `STALE_PINCHBENCH` in `src/report/build_leaderboard.py`.

## ⚠️ Hard-won gotchas (bit us this weekend — bake into any new automation)
1. **Transcript-not-found bug** — PinchBench mangles agent names with dots (`exaone-4.5`→`4-5`) → can't match
   transcripts → all tasks skipped → fake 0.005. Guard: if a pinch log has many "Transcript not found", DISCARD it.
2. **False auto-exclusion** — a single below-random MCQ cell mid-run adds a model to `results/excluded.txt` and
   silently drops it from the board (this hid gemma-4-26b, a #3 model, for hours). Check `results/excluded.txt`.
3. **Completeness gate** — only un-hide a model with ALL 14 counted grid benches present (empty% alone let an
   incomplete gemma-4-e4b onto the board). See the un-hide logic in `scripts/orchestration/fill_batch.sh`.
4. **128K clamp-guard** (in `pinchbench_run.sh`) — reads live `/props n_ctx`, SKIPS if <100K. Trust it; if a model
   isn't in the CTX case list it silently defaults to 32K, so ADD new models to that `case` before pinching.
5. **Server-count zombies** — count `llama-server` EXCLUDING `<defunct>` or you get false "solo-GPU broken" alerts.
6. **pgrep self-kill** — a `kill $(pgrep -f "bash /tmp/x.sh")` also matches YOUR shell if its command line contains
   that string. Kill by exact PID (`ps -eo pid,cmd | awk '$2=="bash" && $3=="/tmp/x.sh"{print $1}'`).

## What lives where
| Component | Size | How it moves |
|---|---|---|
| This repo (code, configs, **results/scored + results/raw**, scripts) | ~82 MB | `git clone` this GitHub repo |
| GGUF model weights | ~108 GB | auto-downloaded from HF by name (`configs/models.yaml`) — need ~110 GB free disk |
| PinchBench harness | separate | `git clone https://github.com/pinchbench/skill.git ~/pinchbench-skill` |
| Secrets (`.hf_token`, `.openrouter_key`) | — | gitignored — **recreate by hand** on the new box |

## New-GPU setup (start to finish)
1. **Clone:** `git clone https://github.com/fluxion-sys-ai/Leaderboard.git edge-intelligence-benchmark && cd edge-intelligence-benchmark`
2. **Python deps:** `pip install -r requirements.txt`
3. **PinchBench sibling:** `git clone https://github.com/pinchbench/skill.git ~/pinchbench-skill` (uses `uv`; it self-provisions on first `uv run`)
4. **llama.cpp:** build/download **b9892** (or newer) → `export LLAMACPP_BIN=/path/to/llama-b9892` (server binary expected at `$LLAMACPP_BIN/llama-server`)
5. **Secrets:** create two files at the repo root — `.hf_token` (HF read token, for GGUF download rate limits) and `.openrouter_key` (OpenRouter key, for the DeepSeek judge)
6. **Disk:** ~110 GB free for GGUFs (the orchestration scripts self-delete each model's weights after use)

## How to run
| Task | Command |
|---|---|
| One model's grid | `python3 run_benchmark.py --models <name> --benchmarks ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl simpleqa` |
| PinchBench (one model) | `bash scripts/pinchbench_run.sh <name>` (128K ctx, top-10 gate, `no_think` auto from config; `FORCE_PINCH=1` bypasses gate; `REASONING_EFFORT=medium` for harmony models) |
| Judge writing (API, no GPU) | `python3 judge_writing.py` |
| Judge SimpleQA (API, no GPU) | `python3 judge_simpleqa.py` |
| Import pinch scores | `python3 import_pinchbench.py` |
| Rescore everything | `python3 rescore_all.py` |
| Build the site | `python3 -m src.report.build_leaderboard` → `leaderboard.html` |

## Dashboard hosting (GitHub Pages)
The interactive `leaderboard.html` is published via **GitHub Pages** from **`docs/index.html`** on `main`.
- **Live URL:** https://fluxion-sys-ai.github.io/Leaderboard/
- **Setup (one-time):** repo → Settings → Pages → **Source: "Deploy from a branch"** → Branch **`main`** → Folder **`/docs`** → Save.
  ⚠️ If Source is left on **"GitHub Actions"** (GitHub's current default) it needs a workflow you don't have → permanent **404**. Must be "Deploy from a branch."
- **Auto-deploy:** every **push** that changes `docs/` triggers a "pages build and deployment" Action → live in ~1–2 min. No re-config needed. (Local edits don't deploy until pushed; hard-refresh to beat the CDN cache.)
- **Update loop:**
  ```bash
  python3 -m src.report.build_leaderboard   # regenerate leaderboard.html
  cp leaderboard.html docs/index.html        # update the Pages copy
  git commit -am "update dashboard" && git push
  ```
- **Visibility:** the repo is **public**, so the Pages site is **public-by-link** (anyone with the URL — company *and* everyone else). A `<meta name="robots" content="noindex">` is baked into the dashboard so it won't hit search engines, but that is NOT access control. Company-only requires **GitHub Enterprise Cloud** + a private/internal repo + Pages visibility = Private. For a quick unlisted alternative: a **secret Gist** served via `gist.githack.com`.
- **Custom domain (optional):** leave blank to use the `github.io` URL; to brand it, enter a subdomain you own and add a DNS `CNAME` → `fluxion-sys-ai.github.io`.

## The knobs (`configs/`)
- **`models.yaml`** — per-model: `gguf` (repo + quant, default Q4_K_M), `no_think` (reasoning models → direct mode),
  `template_kwargs.reasoning_effort` (gpt-oss: low/medium/high), `max_tokens_mult` (2–4; too low truncates CoT → empty).
  Global defaults: `n_ctx` 20480, `temperature` 0.0 (greedy), `max_tokens` 1024.
- **`benchmarks.yaml`** — per-benchmark `sample` size + `max_tokens`.
- **`score_specs.json`** — universal spec block (shown top of the site) + per-score overrides (◆ badges on hover).
- **`hidden_models.json`** — models hidden from the board (contaminated/misleading); orchestration auto-un-hides a
  model once its rerun grid is <15% empty.

## Orchestration (unattended runs)
`scripts/orchestration/` holds the detached "waiter" scripts. They chain **solo-GPU** (one model at a time),
each waiting on the prior via `ps`-grep, and self-delete GGUFs to save disk. Current-era scripts:
- `fill_batch.sh` — new models: preflight → mmlu_pro smoke-gate → auto `no_think`/`max_tokens` → full grid → un-hide (14/14 gate) → push
- `pinch_batch.sh` / `pinch_batch2.sh` / `granite_pinch.sh` — add PinchBench (128K, clamp-guarded, OOM→64K, transcript-bug guard)
- `overnight_watch.sh` — watchdog: audit numbers, re-hide incomplete/contaminated, reap zombies, stall-recovery, auto-push
- `nemotron_rerun.sh`, `gemma_e4b.sh`, `lfm_tess.sh`, … (+ `archive/` of historical). See `scripts/orchestration/README.md`.
⚠️ They hardcode absolute paths (`/tmp/*.sh`, `/home/ubuntu/...`, `LLAMACPP_BIN`) — **update those for the new host**.
⚠️ The `/tmp/*.sh` copies are the *running* instances; the `scripts/orchestration/` copies are the tracked source.
Author commits as `aliixh <aliixhuang@gmail.com>` — **never add a Claude co-author trailer** (standing rule).

## Universal run specs (this snapshot)
`NVIDIA A100-SXM4-40GB · Q4_K_M GGUF · llama.cpp b9892 · greedy (temp 0) · grid n_ctx 20K ·
PinchBench n_ctx 128K · judge DeepSeek-Chat-v3.1 · reasoning models no_think · gpt-oss reasoning_effort=low`
