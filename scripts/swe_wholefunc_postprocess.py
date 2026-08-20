#!/usr/bin/env python3
"""Whole-function repair post-processor for models that emit code fences instead of SEARCH/REPLACE.

qwen3.6-35b-a3b (MoE) will not follow the SEARCH/REPLACE diff format on real SWE prompts — it dumps
the *complete edited function/class* in a ```python fence. Agentless' --diff_format extractor finds
no SEARCH/REPLACE blocks -> empty patch -> 0%. This recovers a real score from those outputs:

  for each bug, for each of the N repair samples:
    - extract each ```python block + the file path (### path) + the def/class it (re)defines
    - locate that same def/class in the ORIGINAL file (saved in repair output.jsonl 'prev_content')
    - splice the new version in and emit a unified git diff
  then majority-vote across the samples -> one patch per bug -> all_preds.jsonl (for swebench eval).

Usage: swe_wholefunc_postprocess.py <key> [--tag orf] -> writes <work>/repair/all_preds_wholefunc.jsonl
"""
import json, re, sys, os, difflib
from collections import Counter

REPO = "/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark"
KEY = sys.argv[1]
TAG = ""
if "--tag" in sys.argv:
    TAG = sys.argv[sys.argv.index("--tag") + 1]
FULL = {"muse": "muse-glimmer-30b", "qwen27": "qwen3.6-27b", "qwen35": "qwen3.6-35b-a3b",
        "gemma": "gemma-4-31b", "qwen38": "qwen3.8-27b"}[KEY]
WORK = f"{REPO}/results/swe_agentless/{KEY}{('-'+TAG) if TAG else ''}"
REP = f"{WORK}/repair"
OUT = f"{REP}/all_preds_wholefunc.jsonl"


def flatten_str(x):
    """prev_content/file_names are irregularly nested; pull out (filename, content) pairs."""
    out = []
    def walk(node):
        if isinstance(node, list):
            for v in node:
                walk(v)
        elif isinstance(node, str) and node:
            out.append(node)
    walk(x)
    return out


def def_span(lines, name, kind):
    """Return (start, end) line indices of the top-level/method `kind name` block, or None."""
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
            cur = len(s) - len(s.lstrip())
            if cur <= indent:          # dedent back to or past the def -> block ended
                break
            j += 1
        return i, j
    return None


def build_patch(orig_content, file_path, new_block):
    """Replace the def/class in new_block into orig_content; return a unified git diff or None."""
    # what does the new block (re)define?
    dm = re.search(r"^(\s*)(def|class)\s+(\w+)", new_block, re.M)
    if not dm:
        return None
    kind, name = dm.group(2), dm.group(3)
    # trim the new block to start at its def/class line (drop stray leading text)
    nb_lines = new_block.splitlines(keepends=True)
    start_idx = next((k for k, l in enumerate(nb_lines) if re.match(rf"^\s*{kind}\s+{re.escape(name)}\b", l)), 0)
    new_func = nb_lines[start_idx:]
    orig_lines = orig_content.splitlines(keepends=True)
    span = def_span(orig_lines, name, kind)
    if not span:
        return None
    s, e = span
    # match the new function's indentation to the original's
    orig_indent = len(orig_lines[s]) - len(orig_lines[s].lstrip())
    new_indent = len(new_func[0]) - len(new_func[0].lstrip())
    shift = orig_indent - new_indent
    if shift > 0:
        new_func = [(" " * shift) + l if l.strip() else l for l in new_func]
    elif shift < 0:
        new_func = [l[-shift:] if l[:-shift].strip() == "" else l for l in new_func]
    if new_func and not new_func[-1].endswith("\n"):
        new_func[-1] += "\n"
    patched = orig_lines[:s] + new_func + orig_lines[e:]
    if patched == orig_lines:
        return None
    diff = difflib.unified_diff(orig_lines, patched, fromfile=f"a/{file_path}", tofile=f"b/{file_path}", n=3)
    body = "".join(diff)
    if not body.strip():
        return None
    return f"diff --git a/{file_path} b/{file_path}\n--- a/{file_path}\n+++ b/{file_path}\n" + \
           "".join(l for l in body.splitlines(keepends=True) if not l.startswith(("--- ", "+++ ")))


def norm(p):
    return "".join(l.strip() for l in p.splitlines() if l.startswith(("+", "-")) and not l.startswith(("+++", "---")))


def main():
    n_ok = 0
    with open(OUT, "w") as fo:
        for line in open(f"{REP}/output.jsonl"):
            d = json.loads(line)
            iid = d["instance_id"]
            files = flatten_str(d.get("file_names"))
            contents = flatten_str(d.get("prev_content"))
            # map filename -> original content
            fmap = {}
            for c in contents:
                # each content is a whole file; find which known filename it is (best effort: pair by order)
                pass
            # pair contents to filenames positionally (both come from the same localized set)
            uniq_files = list(dict.fromkeys(files))
            for i, fn in enumerate(uniq_files):
                if i < len(contents):
                    fmap[fn] = contents[i]
            cands = []
            for raw in (d.get("raw_output") or []):
                text = raw if isinstance(raw, str) else json.dumps(raw)
                for block in re.findall(r"```(?:python)?\n(.*?)```", text, re.S):
                    fm = re.search(r"###\s*(\S+)", block)
                    fpath = fm.group(1) if fm else (uniq_files[0] if uniq_files else None)
                    if not fpath or fpath not in fmap:
                        # try any known file whose content contains the edited def name
                        dm = re.search(r"\b(?:def|class)\s+(\w+)", block)
                        if dm:
                            for fn, c in fmap.items():
                                if re.search(rf"\b(?:def|class)\s+{dm.group(1)}\b", c):
                                    fpath = fn
                                    break
                    if fpath and fpath in fmap:
                        p = build_patch(fmap[fpath], fpath, block)
                        if p:
                            cands.append(p)
            best = ""
            if cands:
                # majority vote by normalized patch
                key = Counter(norm(c) for c in cands).most_common(1)[0][0]
                best = next(c for c in cands if norm(c) == key)
                n_ok += 1
            fo.write(json.dumps({"instance_id": iid, "model_name_or_path": f"{FULL}-wholefunc",
                                 "model_patch": best}) + "\n")
    print(f"[wholefunc] {KEY}: recovered a non-empty patch for {n_ok} bugs -> {OUT}")


if __name__ == "__main__":
    main()
