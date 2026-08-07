#!/usr/bin/env python3
"""Import local-PinchBench results into the leaderboard as a first-class Agentic cell.

PinchBench (the multi-turn OpenClaw agent harness in ~/pinchbench-skill/) is the SAME
benchmark used for the "Agent score", so this is the headline agentic metric.
Its runner writes ~/pinchbench-skill/results/*.json with per-category scores; here we
aggregate score/max_score across categories into a 0-1 score and write it into the
edge-benchmark's results/scored/<model>/pinchbench.json so build_leaderboard picks it up.

We match runs whose model tag is 'openai/edge-<name>' (produced by scripts/pinchbench_run.sh)
back to <name> in models.yaml. Aggregates all result files for a model (one per suite/run).
No GPU. Usage: python import_pinchbench.py
"""
import glob
import json
import os
import re
from collections import defaultdict

from src.utils.helpers import write_json, scored_path

PB_RESULTS = "/home/ubuntu/pinchbench-skill/results"


def main():
    # model -> {"score_sum":.., "max_sum":.., "by_cat": {cat: [score,max]}}
    agg: dict = defaultdict(lambda: {"score": 0.0, "max": 0.0, "by_cat": defaultdict(lambda: [0.0, 0.0])})
    matched = 0
    for f in glob.glob(os.path.join(PB_RESULTS, "*.json")):
        try:
            d = json.load(open(f))
        except (json.JSONDecodeError, OSError):
            continue
        m = re.search(r"edge-(.+)", str(d.get("model", "")))   # only our edge runs
        if not m:
            continue
        model = m.group(1).replace("/", "-")
        matched += 1
        for cat, cs in (d.get("category_scores") or {}).items():
            agg[model]["score"] += cs.get("score", 0.0)
            agg[model]["max"] += cs.get("max_score", 0.0)
            agg[model]["by_cat"][cat][0] += cs.get("score", 0.0)
            agg[model]["by_cat"][cat][1] += cs.get("max_score", 0.0)

    for model, a in agg.items():
        if a["max"] <= 0:
            print(f"  skip {model}: no scored tasks"); continue
        score = round(a["score"] / a["max"], 4)
        by_category = {c: {"score": round(s / mx, 4), "n": None}
                       for c, (s, mx) in a["by_cat"].items() if mx > 0}
        sp = scored_path(model, "pinchbench")
        old = json.load(open(sp)) if sp.exists() else {}
        old.update({"metric": "pinchbench_pct", "score": score,
                    "n": None, "by_category": by_category,
                    "scorer": "pinchbench-harness (official)"})
        write_json(sp, old)
        print(f"  pinchbench/{model}: {score}  (from {a['max']:.0f} max pts)", flush=True)
    print(f"IMPORT DONE — matched {matched} result files", flush=True)


if __name__ == "__main__":
    main()
