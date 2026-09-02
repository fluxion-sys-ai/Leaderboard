#!/usr/bin/env python3
"""Recover SEARCH/REPLACE patches that Agentless dropped because the model omitted the ```python fence.

qwen3.8 (and likely others) emit valid edits as:
    ### path/to/file.py
    <<<<<<< SEARCH
    <original lines>
    =======
    <new lines>
    >>>>>>> REPLACE
but WITHOUT wrapping in ```python...```, so Agentless' extractor finds nothing -> empty patch.
This scans the raw generations, applies each SEARCH->REPLACE (exact match) onto the cached original
file text (from structures/), and emits a unified git diff -> all_preds_recovered.jsonl.

Usage: swe_recover_dropped.py <key> [--tag orf] [--sample configs/swe_lite_sample.txt]
REPORT-ONLY: writes repair/all_preds_recovered.jsonl; does NOT touch the board or scored files.
"""
import json, sys, os, re, difflib

REPO = "/home/aliixh/.openclaw/workspace/edge-intelligence-benchmark"
KEY = sys.argv[1]
TAG = sys.argv[sys.argv.index("--tag") + 1] if "--tag" in sys.argv else "orf"
SAMPLE = sys.argv[sys.argv.index("--sample") + 1] if "--sample" in sys.argv else "configs/swe_lite_sample.txt"
FULL = {"muse": "muse-glimmer-30b", "qwen27": "qwen3.6-27b", "qwen35": "qwen3.6-35b-a3b",
        "gemma": "gemma-4-31b", "qwen38": "qwen3.8-27b"}[KEY]
WORK = f"{REPO}/results/swe_agentless/{KEY}{('-'+TAG) if TAG else ''}"
REP, STRUCT = f"{WORK}/repair", f"{WORK}/structures"

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

# ---- parse SEARCH/REPLACE blocks, WITH or WITHOUT a `### path` marker ----
# Some models wrap edits in ```python fences and omit the `### path`, so Agentless can't tell which
# file to patch and drops them. We capture the block regardless, and infer the file if the path is absent.
SR = re.compile(
    r"<<<<<<<\s*SEARCH\s*\n(?P<search>.*?)\n=======\s*\n(?P<replace>.*?)\n>>>>>>>\s*REPLACE", re.DOTALL)
PATH_RE = re.compile(r"###\s*([^\n`]+?\.[A-Za-z0-9_]+)")

def iter_files(struct, prefix=""):
    if not isinstance(struct, dict):
        return
    for k, v in struct.items():
        if isinstance(v, dict):
            if "text" in v:
                yield (f"{prefix}{k}", v)
            else:
                yield from iter_files(v, f"{prefix}{k}/")

def blocks_from(text):
    for m in SR.finditer(text):
        pre = text[max(0, m.start() - 300):m.start()]      # look back for a `### path` marker
        paths = PATH_RE.findall(pre)
        path = paths[-1].strip() if paths else None
        yield path, m.group("search"), m.group("replace")

def make_diff(path, orig, new):
    a = orig.splitlines(keepends=True)
    b = new.splitlines(keepends=True)
    if not orig.endswith("\n"): a[-1] += "\n"
    if not new.endswith("\n"): b[-1] += "\n"
    ud = difflib.unified_diff(a, b, fromfile=f"a/{path}", tofile=f"b/{path}")
    body = "".join(ud)
    if not body.strip():
        return ""
    return f"diff --git a/{path} b/{path}\n" + body

def recover_instance(iid, raw_lists):
    try:
        struct = json.load(open(f"{STRUCT}/{iid}.json"))
        struct = struct.get("structure", struct) if isinstance(struct, dict) else struct
    except Exception:
        return None
    # index all files once for path inference (only used when a block lacks `### path`)
    all_files = None
    def infer_path(search):
        nonlocal all_files
        if all_files is None:
            all_files = [(p, "\n".join(n["text"]) + "\n" if isinstance(n.get("text"), list) else n.get("text", ""))
                         for p, n in iter_files(struct)]
        key = "\n".join([l for l in search.splitlines() if l.strip()][:4])   # first real lines
        for p, txt in all_files:
            if txt and (search in txt or (key and key in txt)):
                return p
        return None
    # scan every sample's raw text for a usable block that applies exactly
    for raw in raw_lists:
        text = raw if isinstance(raw, str) else json.dumps(raw)
        diffs, edited = [], {}
        for path, search, replace in blocks_from(text):
            orig = get_file_text(struct, path) if path else None
            if orig is None:                        # no/invalid path -> infer file from SEARCH text
                path = infer_path(search)
                orig = get_file_text(struct, path) if path else None
            if orig is None:
                continue
            cur = edited.get(path, orig)
            if search in cur:                       # exact-match apply
                edited[path] = cur.replace(search, replace, 1)
        for path, newtext in edited.items():
            d = make_diff(path, get_file_text(struct, path), newtext)
            if d:
                diffs.append(d)
        if diffs:
            return "\n".join(diffs)
    return None

def main():
    ids = [l.strip() for l in open(SAMPLE) if l.strip()]
    # current selected patches
    cur = {}
    ap = f"{REP}/all_preds.jsonl"
    if os.path.exists(ap):
        for l in open(ap):
            d = json.loads(l); cur[d["instance_id"]] = (d.get("model_patch") or "").strip()
    # raw generations per instance
    raws = {}
    for l in open(f"{REP}/output.jsonl"):
        d = json.loads(l); iid = d.get("instance_id")
        r = d.get("raw_output") or d.get("all_generations") or []
        if isinstance(r, str): r = [r]
        raws[iid] = r
    out, n_empty, n_recovered = [], 0, 0
    for iid in ids:
        patch = cur.get(iid, "")
        if patch:
            out.append({"instance_id": iid, "model_name_or_path": FULL, "model_patch": patch})
            continue
        n_empty += 1
        rec = recover_instance(iid, raws.get(iid, []))
        if rec:
            n_recovered += 1
            out.append({"instance_id": iid, "model_name_or_path": FULL, "model_patch": rec})
            print(f"  RECOVERED {iid}")
        else:
            out.append({"instance_id": iid, "model_name_or_path": FULL, "model_patch": ""})
            print(f"  no-recover {iid}")
    outp = f"{REP}/all_preds_recovered.jsonl"
    with open(outp, "w") as f:
        for o in out:
            f.write(json.dumps(o) + "\n")
    print(f"\nSUMMARY: {len(ids)} strat instances | empty before: {n_empty} | recovered: {n_recovered}")
    print(f"wrote {outp}")

if __name__ == "__main__":
    main()
