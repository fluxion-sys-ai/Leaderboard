#!/usr/bin/env python3
"""Re-score every cached cell offline (no GPU): recomputes scores + splits +
failure_breakdown from results/raw/ using the current benchmark code. Cheap."""
import os, sys, glob, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from src.benchmarks import get_benchmark
from src.utils.helpers import read_jsonl, write_json, scored_path, strip_reasoning, load_yaml, REPO_ROOT

bcfg = {b["name"]: b for b in load_yaml(REPO_ROOT/"configs"/"benchmarks.yaml")["benchmarks"]}
# Benchmarks whose real score comes from an external judge/grader (judge_writing.py etc.);
# their in-repo aggregate() returns {score: None, judge_pending: True} by design, so we
# MUST NOT run rescore on them — it would clobber the real judge scores with None.
JUDGE_BASED = {"writing", "simpleqa"}

for rp in glob.glob("results/raw/*/*.jsonl"):
    model = rp.split("/")[-2]; bname = rp.split("/")[-1][:-6]
    if bname not in bcfg or bname in JUDGE_BASED:
        continue
    bench = get_benchmark(bname, bcfg[bname])
    tasks = {t.task_id: t for t in bench.load()}
    rows = read_jsonl(rp)
    gens = {r["task_id"]: strip_reasoning(r["output"]) for r in rows}
    per = []
    for tid, out in gens.items():
        if tid in tasks:
            res = bench.score(tasks[tid], out); res["category"] = tasks[tid].meta.get("category")
            per.append(res)
    agg = bench.aggregate(per)
    sp = scored_path(model, bname)
    old = json.load(open(sp)) if sp.exists() else {}          # keep perf + repro stamp if present
    old.update(agg)
    write_json(sp, old)
    print(f"rescored {model}/{bname}: {agg.get('score')}", flush=True)
print("RESCORE DONE", flush=True)
