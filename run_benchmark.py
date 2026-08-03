#!/usr/bin/env python3
"""Edge-Intelligence-Benchmark — main CLI / orchestrator.

Flow (the ONLY orchestration in the repo; registries + interfaces do the rest):

    for each model in models.yaml:
        start its llama.cpp server (load GGUF once)
        for each benchmark in benchmarks.yaml:
            load tasks (pull + cache from HF)
            for each task not already generated:      # resumable
                generate  -> append to results/raw/<model>/<benchmark>.jsonl
            score every generation
            write results/scored/<model>/<benchmark>.json

Every (model, benchmark) is its own pair of files, so you can re-run one cell,
resume a crash, or re-score without regenerating.

Usage:
    python run_benchmark.py                      # full grid from the configs
    python run_benchmark.py --models phi-4-mini-instruct --benchmarks ifeval
"""
from __future__ import annotations
import argparse
import sys
import time

from src.utils.helpers import (
    load_yaml, REPO_ROOT, RESULTS, raw_path, scored_path, read_jsonl, write_json,
    done_task_ids, append_jsonl, sample_tasks, strip_reasoning,
)
from src.models import get_runner
from src.benchmarks import get_benchmark
from src.models_fetch import ensure_gguf   # resolves/downloads the GGUF for a model


# Multiple-choice benchmarks and their random-guess floor. A WORKING model cannot
# score below chance here (worst case it guesses); a below-floor score means the
# output is degenerate/unparseable -> the model is broken and gets aborted early.
# Broken-model floor: ONLY mmlu_pro (broad 10-way MCQ). A truly broken model (bad
# chat-template/arch -> garbage) scores near-zero here. GPQA was REMOVED as a floor:
# it's graduate-level science and verbose/thinking models legitimately score near-random
# (they get truncated mid-reasoning before emitting a letter) — that's not "broken", and
# using it as a floor wrongly excluded 6 valid models (2026-08-03). A single hard
# benchmark must never delete a whole model.
BROKEN_FLOORS = {"mmlu_pro": 0.10}


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def record_failure(root, model: str, benchmark, phase: str, err: Exception) -> None:
    """Persist a failure to results/failures.jsonl so reasons survive log loss.

    phase is one of: 'model_load' (server/GGUF wouldn't load — e.g. an arch the
    pinned llama.cpp can't read) or 'cell' (one benchmark cell errored). Each row
    is self-describing; the file is append-only and safe to read/grep anytime.
    """
    append_jsonl(root / "failures.jsonl", {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "model": model,
        "benchmark": benchmark,          # None for a whole-model failure
        "phase": phase,
        "error_type": type(err).__name__,
        "error": str(err)[:500],
    })


def run_cell(runner, benchmark, model_name: str, root=RESULTS) -> dict:
    """Run one (model, benchmark) cell: generate (resumable) then score.

    Expansion-safe: when `sample` is raised, we KEEP every prompt already run and
    only add brand-new ones up to the new target — prompts are never repeated and
    prior work is never wasted.
    """
    all_tasks = benchmark.load()
    n = benchmark.cfg.get("sample")
    sampled = sample_tasks(all_tasks, n, benchmark.cfg.get("seed", 42))
    rpath = raw_path(model_name, benchmark.name, root)
    already = done_task_ids(model_name, benchmark.name, root)

    if n is None:
        tasks = sampled
    else:
        by_id = {t.task_id: t for t in all_tasks}
        kept = [by_id[i] for i in already if i in by_id]            # keep prior prompts
        fresh = [t for t in sampled if t.task_id not in already]    # only new prompts
        tasks = kept + fresh[: max(0, n - len(kept))]
    todo = [t for t in tasks if t.task_id not in already]
    log(f"  {benchmark.name}: {len(tasks)} tasks, {len(already)} cached, {len(todo)} to run")

    # Reasoning models (long CoT) need a bigger budget or they get truncated
    # before the final answer. max_tokens_mult scales the benchmark's cap per-model.
    mt = benchmark.cfg.get("max_tokens")
    mult = runner.cfg.get("max_tokens_mult", 1)
    eff_max = int(mt * mult) if mt else None
    for i, task in enumerate(todo, 1):
        messages = benchmark.build_messages(task)
        out = runner.generate(messages, max_tokens=eff_max)
        # Persist EVERY field per task — nothing recomputed later needs a re-run.
        append_jsonl(rpath, {
            "task_id": task.task_id, "output": out.text,
            "n_tokens": out.n_tokens, "prompt_tokens": out.prompt_tokens,
            "prefill_tps": out.prefill_tps, "decode_tps": out.decode_tps,
            "prefill_ms": out.prefill_ms, "decode_ms": out.decode_ms, "total_ms": out.total_ms,
            "spec": out.spec,
        })
        if i % 25 == 0:
            log(f"    {i}/{len(todo)}")

    # Score every generation (cheap — re-runnable without touching the model).
    rows = read_jsonl(rpath)
    # strip chain-of-thought before grading (raw keeps the full text)
    gens = {r["task_id"]: strip_reasoning(r["output"]) for r in rows}
    per_task = []
    for t in tasks:
        res = benchmark.score(t, gens.get(t.task_id, ""))
        res["category"] = t.meta.get("category")   # carry category for split reporting
        per_task.append(res)
    summary = benchmark.aggregate(per_task)

    # Aggregate the full telemetry. Median = robust to outliers/warmup.
    def _median(key):
        vals = sorted(r.get(key, 0) for r in rows if r.get(key))
        return round(vals[len(vals) // 2], 2) if vals else 0.0

    def _mean(key):
        vals = [r.get(key, 0) for r in rows if r.get(key)]
        return round(sum(vals) / len(vals), 2) if vals else 0.0

    perf = {
        "prefill_tps": _median("prefill_tps"),   # Fluxion Prefill column
        "decode_tps": _median("decode_tps"),     # Fluxion Decode column
        "ttft_ms": _median("prefill_ms"),        # Fluxion TTFT metric
        "mean_prompt_tokens": _mean("prompt_tokens"),
        "mean_completion_tokens": _mean("n_tokens"),
        "total_gen_tokens": sum(r.get("n_tokens", 0) for r in rows),
        # resource footprint (model-level, sampled across the whole run)
        "model_load_s": runner.load_seconds,
        "gguf_mb": round(runner.gguf_bytes / 1e6, 1),
        "peak_vram_mb": runner.peak_vram_mb,
    }
    # Speculative-decoding rollup — only present if a drafter was attached.
    specs = [r["spec"] for r in rows if r.get("spec")]
    if specs:
        # per-position acceptance: mean at each position across requests (ragged-safe)
        maxlen = max((len(s.get("per_pos_acceptance", [])) for s in specs), default=0)
        per_pos = []
        for i in range(maxlen):
            vals = [s["per_pos_acceptance"][i] for s in specs
                    if len(s.get("per_pos_acceptance", [])) > i]
            per_pos.append(round(sum(vals) / len(vals), 4) if vals else 0.0)
        tot_draft = sum(s.get("draft_n", 0) for s in specs)
        tot_acc = sum(s.get("draft_n_accepted", 0) for s in specs)
        perf["spec"] = {
            "per_pos_acceptance": per_pos,                          # the array you wanted
            "tau": round(sum(s.get("tau", 0) for s in specs) / len(specs), 3),
            "accept_rate": round(tot_acc / tot_draft, 4) if tot_draft else 0.0,
            "draft_n": tot_draft, "draft_n_accepted": tot_acc,
        }

    summary.update({
        "model": model_name, "benchmark": benchmark.name,
        # full reproducibility stamp
        "quant": runner.cfg.get("quant"), "runner": runner.cfg.get("runner"),
        "n_ctx": runner.cfg.get("n_ctx"), "temperature": runner.cfg.get("temperature"),
        "gguf_path": runner.cfg.get("gguf_path"), "run_ts": int(time.time()),
        "perf": perf,
    })
    write_json(scored_path(model_name, benchmark.name, root), summary)
    return summary


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="*", help="subset of model names (default: all)")
    ap.add_argument("--benchmarks", nargs="*", help="subset of benchmark names (default: all)")
    ap.add_argument("--limit", type=int, help="cap tasks per benchmark (for smoke runs)")
    ap.add_argument("--spec", action="store_true",
                    help="speculative-decoding pass: attach each model's draft, "
                         "collect per-position acceptance; writes to results/spec/")
    args = ap.parse_args()

    mcfg = load_yaml(REPO_ROOT / "configs" / "models.yaml")
    bcfg = load_yaml(REPO_ROOT / "configs" / "benchmarks.yaml")
    defaults = mcfg.get("defaults", {})

    seed = bcfg.get("seed", 42)
    models = [m for m in mcfg["models"] if not args.models or m["name"] in args.models]
    benches = [b for b in bcfg["benchmarks"] if not args.benchmarks or b["name"] in args.benchmarks]
    for b in benches:
        b.setdefault("seed", seed)     # global seed unless the benchmark overrides

    root = RESULTS / "spec" if args.spec else RESULTS
    for m in models:
        # A failing model must NOT kill the whole run — log it and move on.
        try:
            cfg = {**defaults, **m}                     # per-model overrides win
            if args.spec:
                if not m.get("draft_gguf"):             # no compatible drafter → skip
                    log(f"skip {m['name']}: no draft_gguf (no vocab-compatible drafter)")
                    continue
                cfg["draft"] = ensure_gguf(f"{m['name']}_draft", m["draft_gguf"])
            cfg["gguf_path"] = ensure_gguf(m["name"], m["gguf"])
            log(f"model: {m['name']}  ({cfg['quant']}){'  +spec' if args.spec else ''}")
            with get_runner(cfg["runner"], m["name"], cfg) as runner:
                for b in benches:
                    # Likewise: a broken benchmark skips its cell, never the run.
                    try:
                        bb = {**b, "sample": args.limit} if args.limit else b
                        summary = run_cell(runner, get_benchmark(bb["name"], bb), m["name"], root)
                        log(f"  -> {b['name']}: {summary['metric']}={summary['score']}"
                            + (f" | tau={summary['perf'].get('spec',{}).get('tau')}" if args.spec else ""))
                        # EARLY ABORT: below the random-guess floor on a multiple-choice cell is
                        # impossible for working output — it means degenerate/unparseable generation
                        # (bad chat template, unsupported arch). Drop the model, don't grind for hours.
                        floor = BROKEN_FLOORS.get(b["name"])
                        if floor is not None and (summary.get("score") or 0) < floor:
                            log(f"!! {m['name']} ABORTED — {b['name']}={summary.get('score')} is BELOW "
                                f"random floor {floor}; output is broken. Excluding model, moving on.")
                            record_failure(root, m["name"], b["name"], "aborted_broken", RuntimeError(
                                f"below random floor on {b['name']} ({summary.get('score')} < {floor}) "
                                "— likely chat-template / arch mismatch"))
                            with open(root / "excluded.txt", "a") as f:
                                f.write(m["name"] + "\n")
                            break                       # skip this model's remaining cells
                    except Exception as e:
                        log(f"  !! {b['name']} FAILED ({type(e).__name__}: {str(e)[:120]}) — skipping cell")
                        record_failure(root, m["name"], b["name"], "cell", e)
        except Exception as e:
            log(f"!! model {m['name']} FAILED ({type(e).__name__}: {str(e)[:120]}) — skipping model")
            record_failure(root, m["name"], None, "model_load", e)
    log("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
