#!/usr/bin/env python3
"""Majority-vote patch selection that IGNORES empty patches.

Agentless' rerank.py votes over all N processed samples including empties. When some samples are
empty (e.g. a provider returned fewer than n samples and our repair.py guard padded the slots with
empty patches), the empty "patch" can win the vote for a bug that actually had 1+ valid patches ->
that bug ends up with an empty prediction -> it isn't evaluated -> the board's completeness gate
blanks the whole cell. This picks the most-common NON-EMPTY normalized patch per bug, so any bug
with at least one real patch gets a real prediction. Bugs with all-empty samples stay empty (the
model genuinely produced no fix).

Usage: swe_nonempty_vote.py <repair_dir> <num_samples> <model_name> <output_file>
"""
import json, sys, os, re
from collections import Counter, OrderedDict

rep, ns, model, out = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]

# collect per-instance list of candidate patches across the N processed sample files
cand = OrderedDict()  # instance_id -> [patch, ...]
for i in range(ns):
    p = os.path.join(rep, f"output_{i}_processed.jsonl")
    if not os.path.exists(p):
        continue
    for line in open(p):
        d = json.loads(line)
        iid = d.get("instance_id")
        patch = d.get("model_patch", "") or ""
        cand.setdefault(iid, []).append(patch)

def norm(p):
    # normalize a diff to its changed lines (ignore hunk headers / whitespace-only diffs)
    return "".join(l.strip() for l in p.splitlines()
                   if l.startswith(("+", "-")) and not l.startswith(("+++", "---")))

n_real = 0
with open(out, "w") as fo:
    for iid, patches in cand.items():
        nonempty = [p for p in patches if p.strip()]
        best = ""
        if nonempty:
            # majority vote among NON-EMPTY patches, by normalized content
            keyed = [(norm(p), p) for p in nonempty]
            top = Counter(k for k, _ in keyed if k).most_common(1)
            if top:
                best = next(p for k, p in keyed if k == top[0][0])
            else:
                best = nonempty[0]
            n_real += 1
        fo.write(json.dumps({"instance_id": iid, "model_name_or_path": model, "model_patch": best}) + "\n")

print(f"[nonempty-vote] {model}: {n_real}/{len(cand)} bugs got a non-empty patch -> {out}")
