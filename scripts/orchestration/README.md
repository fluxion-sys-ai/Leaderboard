# Orchestration scripts

Detached "waiter" scripts that run the benchmark **unattended, solo-GPU** (one model/server at a time).
Each sleeps until the jobs it depends on are gone (`ps`-grep on the other scripts + `run_benchmark`/pinch
processes), then does its work and self-deletes GGUF weights to free disk. They were developed live in
`/tmp` and copied here for backup/reproducibility.

⚠️ **Paths are hardcoded** (`/tmp/<name>.sh`, `/home/aliixh/edge-intelligence-benchmark`, `/home/aliixh/llama.cpp/llama-b9892`).
Update them for a new host before reusing. The wait-conditions reference the scripts by their `/tmp/*.sh` path.

## Current pipeline (this snapshot — solo-GPU chain, in order)
1. `stage2_newmodels.sh` — new large models grid + pinch (exaone, gpt-oss)
2. `ornith_rerun.sh` — ornith grid rerun (no_think) + pinch + final judge sweep
3. `gptoss_medium.sh` — gpt-oss reasoning_effort=medium rerun (bfcl/babilong/zebra + pinch); writes score_specs.json overrides
4. `qwen_128k_fix.sh` — qwen2.5-7b / qwen3-8b / qwen3.5-9b 128K pinch (+ qwen3.5-9b grid-fill, + exaone FORCE pinch)
5. `gemma_last.sh` — gemma-4-31b grid + pinch (may fail to load on b9892)
6. `gemma_e4b.sh` — gemma-4-e4b grid rerun (no_think)
7. `lfm_tess.sh` — tail grid reruns: tess / lfm2.5 / qwen3-8b / gemma-4-12b (auto-un-hides clean ones)

## Pattern (how to write another)
- Wait loop: `while ps -eo cmd | grep -qE "bash /tmp/(<deps>)\.sh$" || pgrep -f "run_benchmark.py --models" || pgrep -f "benchmark.py --model openai/edge-"; do sleep 300; done`
- `pkill -f llama-server; sleep 8` between models (free the port/VRAM).
- Verify config before running (e.g. `no_think` present) so a rerun can't silently reproduce a bug.
- Clamp-guard for 128K pinch (verify `/props` n_ctx ≥ 100000 before trusting a run).
- `rm -rf models/<name>` after each model to stay under disk.
- Rebuild the site (`python3 -m src.report.build_leaderboard`) at the end.

The 28 earlier chains are kept for provenance in **`archive/`** — not part of the current pipeline; safe to ignore.
