# MIGRATION — moving this benchmark to a new GPU

Everything you need is in **this repo** + the **public model weights** (auto-downloaded) + one **sibling
skill repo**. Repo payload is ~82 MB; the ~108 GB of GGUF weights are **not** stored here — they stream
from Hugging Face on first run.

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
each waiting on the prior via `ps`-grep, and self-delete GGUFs to save disk. See
`scripts/orchestration/README.md` for the current pipeline vs. historical scripts.
⚠️ They hardcode absolute paths (`/tmp/*.sh`, `/home/ubuntu/...`) — **update those for the new host** before reusing.

## Universal run specs (this snapshot)
`NVIDIA A100-SXM4-40GB · Q4_K_M GGUF · llama.cpp b9892 · greedy (temp 0) · grid n_ctx 20K ·
PinchBench n_ctx 128K · judge DeepSeek-Chat-v3.1 · reasoning models no_think · gpt-oss reasoning_effort=low`
