#!/usr/bin/env python3
"""Whole-function repair post-processor (v2) for models that emit code fences, not SEARCH/REPLACE.

qwen3.6-35b-a3b (MoE) never produces the SEARCH/REPLACE diff format on real SWE prompts — it dumps
the complete edited function/class in a ```python fence. Agentless' --diff_format extractor finds
nothing -> empty patch -> 0%. This recovers a real score from those outputs:

  for each bug, for each of the N repair samples:
    - extract each ```python block + the def/class it (re)defines (skip test_* defs)
    - find the ORIGINAL file:  the `### path` marker if present, else the file-level-localized
      candidate whose source actually contains that def/class
    - get the original file TEXT from structures/<iid>.json (Agentless' cached repo), splice the new
      version in, and emit a unified git diff
  then majority-vote (non-empty) across the samples -> one patch per bug -> all_preds.jsonl.

v1 relied on repair 'prev_content' (empty for many bugs after a localize hiccup) and got 1/20; v2
uses structures/ (always present) + candidate-file search and recovers most function edits.

Usage: swe_wholefunc_postprocess.py <key> [--tag orf]  ->  writes <work>/repair/all_preds.jsonl
"""
import json, re, sys, os, difflib
from collections import Counter

REPO = "/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark"
KEY = sys.argv[1]
TAG = sys.argv[sys.argv.index("--tag") + 1] if "--tag" in sys.argv else ""
FULL = {"muse": "muse-glimmer-30b", "qwen27": "qwen3.6-27b", "qwen35": "qwen3.6-35b-a3b",
        "gemma": "gemma-4-31b", "qwen38": "qwen3.8-27b"}[KEY]
WORK = f"{REPO}/results/swe_agentless/{KEY}{('-'+TAG) if TAG else ''}"
REP, STRUCT = f"{WORK}/repair", f"{WORK}/structures"
OUT = f"{REP}/all_preds.jsonl"


def get_file_text(struct, path):
    node = struct
    for p in path.split("/"):
        if isinstance(node, dict) and p in node:
            node = node[p]
        else:
            return None
    if isinstance(node, dict) and "text" in node:
        t = node["text"]
        return "\n".join(t) + "\n" if isinstance(t, list) else t
    return None


def iter_files(struct, prefix=""):
    """Yield (path, node) for every file (dict with 'text') in the structure."""
    if not isinstance(struct, dict):
        return
    for k, v in struct.items():
        if isinstance(v, dict):
            if "text" in v:
                yield (f"{prefix}{k}", v)
            else:
                yield from iter_files(v, f"{prefix}{k}/")


def def_span(lines, name, kind):
    pat = re.compile(rf"^(\s*){kind}\s+{re.escape(name)}\b")
    for i, ln in enumerate(lines):
        m = pat.match(ln)
        if not m:
            continue
        indent = len(m.group(1))
        j = i + 1
        while j < len(lines):
            s = lines[j]
            if s.strip() == "" or s.lstrip().startswith("#"):
                j += 1
                continue
            if len(s) - len(s.lstrip()) <= indent:
                break
            j += 1
        return i, j
    return None


def build_patch(orig, fpath, block):
    dm = re.search(r"^(\s*)(def|class)\s+(\w+)", block, re.M)
    if not dm:
        return None
    kind, name = dm.group(2), dm.group(3)
    if name.lower().startswith("test"):
        return None  # qwen35 sometimes writes a test instead of the fix — not a patch
    nb = block.splitlines(keepends=True)
    si = next((k for k, l in enumerate(nb) if re.match(rf"^\s*{kind}\s+{re.escape(name)}\b", l)), 0)
    newf = nb[si:]
    ol = orig.splitlines(keepends=True)
    span = def_span(ol, name, kind)
    if not span:
        return None
    s, e = span
    oi = len(ol[s]) - len(ol[s].lstrip())
    ni = len(newf[0]) - len(newf[0].lstrip())
    shift = oi - ni
    if shift > 0:
        newf = [(" " * shift) + l if l.strip() else l for l in newf]
    if newf and not newf[-1].endswith("\n"):
        newf[-1] += "\n"
    patched = ol[:s] + newf + ol[e:]
    if patched == ol:
        return None
    body = "".join(l for l in difflib.unified_diff(ol, patched, n=3)
                   if not l.startswith(("--- ", "+++ ")))
    if not body.strip():
        return None
    return f"diff --git a/{fpath} b/{fpath}\n--- a/{fpath}\n+++ b/{fpath}\n" + body


def norm(p):
    return "".join(l.strip() for l in p.splitlines()
                   if l.startswith(("+", "-")) and not l.startswith(("+++", "---")))


def main():
    n_ok = 0
    total = 0
    with open(OUT, "w") as fo:
        for line in open(f"{REP}/output.jsonl"):
            d = json.loads(line)
            iid = d["instance_id"]
            total += 1
            sf = f"{STRUCT}/{iid}.json"
            struct = json.load(open(sf))["structure"] if os.path.exists(sf) else None
            cands = []
            if struct:
                for raw in (d.get("raw_output") or []):
                    t = raw if isinstance(raw, str) else json.dumps(raw)
                    for block in re.findall(r"```(?:python)?\n(.*?)```", t, re.S):
                        dm = re.search(r"^\s*(def|class)\s+(\w+)", block, re.M)
                        if not dm:
                            continue
                        kind, name = dm.group(1), dm.group(2)
                        fm = re.search(r"###\s*(\S+)", block)
                        fpaths = []
                        if fm:
                            fpaths = [fm.group(1)]
                        else:
                            # find file(s) that actually contain this def/class
                            for path, node in iter_files(struct):
                                txt = node.get("text")
                                if isinstance(txt, list):
                                    src = "\n".join(str(x) for x in txt)
                                elif isinstance(txt, str):
                                    src = txt
                                else:
                                    continue
                                if re.search(rf"^\s*{kind}\s+{re.escape(name)}\b", src, re.M):
                                    fpaths.append(path)
                                    if len(fpaths) >= 3:
                                        break
                        for fpath in fpaths:
                            orig = get_file_text(struct, fpath)
                            if orig:
                                p = build_patch(orig, fpath, block)
                                if p:
                                    cands.append(p)
                                    break
            best = ""
            if cands:
                key = Counter(norm(c) for c in cands).most_common(1)[0][0]
                best = next(c for c in cands if norm(c) == key)
                n_ok += 1
            fo.write(json.dumps({"instance_id": iid, "model_name_or_path": f"{FULL}-full",
                                 "model_patch": best}) + "\n")
    print(f"[wholefunc-v2] {KEY}: recovered a non-empty patch for {n_ok}/{total} bugs -> {OUT}")


if __name__ == "__main__":
    main()
