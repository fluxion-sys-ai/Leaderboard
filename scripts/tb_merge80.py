#!/usr/bin/env python3
"""Merge two TerminalBench results.json files (the 24-task stratified sample + the remaining-56 run)
into a single full-80 results.json. Dedupes per-task by task_id (the remaining run wins on conflict),
recomputes n_resolved / n_unresolved / resolved_ids / unresolved_ids / accuracy.

Usage: tb_merge80.py <base_results.json> <extra_results.json> <out_results.json>
"""
import json
import sys


def load(p):
    try:
        return json.load(open(p))
    except Exception:
        return None


def main():
    base_p, extra_p, out_p = sys.argv[1], sys.argv[2], sys.argv[3]
    base, extra = load(base_p), load(extra_p)
    if base is None and extra is None:
        print(f"tb_merge80: both inputs missing ({base_p}, {extra_p})")
        sys.exit(1)
    base = base or {"results": []}
    extra = extra or {"results": []}

    # per-task dedupe: extra (remaining-56) overrides base (24-sample) on the same task_id
    by_task = {}
    for r in base.get("results", []):
        by_task[r.get("task_id")] = r
    for r in extra.get("results", []):
        by_task[r.get("task_id")] = r
    results = list(by_task.values())

    resolved = sorted({t for t, r in by_task.items() if r.get("is_resolved")})
    unresolved = sorted({t for t, r in by_task.items() if not r.get("is_resolved")})
    n_res, n_unres = len(resolved), len(unresolved)
    total = n_res + n_unres

    out = dict(base)  # keep id/pass_at_k shape from base
    out["results"] = results
    out["resolved_ids"] = resolved
    out["unresolved_ids"] = unresolved
    out["n_resolved"] = n_res
    out["n_unresolved"] = n_unres
    out["accuracy"] = (n_res / total) if total else 0.0
    out["_merged_from"] = [base_p, extra_p]
    json.dump(out, open(out_p, "w"), indent=2)
    print(f"tb_merge80: {total} tasks -> {n_res} resolved ({out['accuracy']*100:.1f}%) written to {out_p}")


if __name__ == "__main__":
    main()
