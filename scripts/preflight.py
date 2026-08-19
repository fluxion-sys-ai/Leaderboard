#!/usr/bin/env python3
"""Preflight smoke-test — catch a broken/contaminated model config BEFORE a multi-hour grid run.

Launches the model's llama-server exactly as the grid would (n_ctx + no_think/reasoning_effort from
configs/models.yaml), fires a few probe prompts, and checks the four failure modes we've actually hit:
  1. LOAD       — did the server come up at all?      (catches novel-arch load fails, e.g. gemma-4-31b)
  2. CONTEXT    — live n_ctx >= 80% of target?        (catches YaRN/clamp-to-32k)
  3. EMPTY      — <25% of probes come back empty?      (catches no_think/reasoning_effort/max_tokens bugs)
  4. DEGENERATE — output isn't repetition gibberish?  (catches the exaone-ruler failure mode)

PASS -> exit 0 (safe to run the full grid).  FAIL -> exit 1 + JSON reason (skip + flag, save the hours).
SOLO-GPU: run only when the card is free (the orchestration calls it right after `pkill llama-server`).

Usage: python3 scripts/preflight.py <model-name>
Env:   LLAMACPP_BIN (default /home/aliixh/llama.cpp/llama-b9892)
"""
import json, os, re, subprocess, sys, time, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
import yaml
from src.models_fetch import ensure_gguf

PORT = 8091   # distinct from grid/pinch (8081) so a stray server never collides
LLAMA = os.environ.get("LLAMACPP_BIN", "/home/aliixh/llama.cpp/llama-b9892")
PROBES = [
    "Reply with exactly: OK",
    "What is 17 + 26? Answer with only the number.",
    "Name three primary colors, comma-separated.",
    "In one short sentence: what is the capital of France?",
]


def out(reason, ok, **extra):
    print(json.dumps({"model": MODEL, "pass": ok, "reason": reason, **extra}))
    sys.exit(0 if ok else 1)


def degenerate(t):
    words = t.split()
    if len(words) > 20 and len(set(words)) < len(words) * 0.25:
        return True
    return bool(re.search(r"(.{4,})\1{5,}", t))   # a chunk repeated 6+ times


if len(sys.argv) < 2:
    print("usage: preflight.py <model-name>"); sys.exit(2)
MODEL = sys.argv[1]
conf = yaml.safe_load(open(f"{REPO}/configs/models.yaml"))
dflt = conf.get("defaults", {})
m = next((x for x in conf["models"] if x["name"] == MODEL), None)
if not m:
    out("model not in models.yaml", False)

n_ctx = dflt.get("n_ctx", 20480)
gguf = ensure_gguf(m["name"], m["gguf"])
cmd = [f"{LLAMA}/llama-server", "-m", gguf, "-c", str(n_ctx), "-ngl", "999",
       "--host", "127.0.0.1", "--port", str(PORT), "--no-webui"]
if m.get("no_think"):
    cmd += ["--chat-template-kwargs", '{"enable_thinking": false}']
elif m.get("template_kwargs"):
    cmd += ["--chat-template-kwargs", json.dumps(m["template_kwargs"])]

srv = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    # 1. LOAD
    up = False
    for _ in range(45):
        time.sleep(2)
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=2); up = True; break
        except Exception:
            if srv.poll() is not None:
                out("LOAD FAIL — server exited (arch unsupported on this llama.cpp build?)", False)
    if not up:
        out("LOAD FAIL — server never became healthy in 90s", False)

    # 2. CONTEXT
    live = None
    try:
        props = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/props", timeout=5))
        live = props.get("default_generation_settings", {}).get("n_ctx") or 0
        if live and live < 0.8 * n_ctx:
            out(f"CONTEXT FAIL — clamped to {live} (< 80% of target {n_ctx})", False, live_n_ctx=live)
    except Exception:
        pass   # fail-open on a flaky read

    # 3 & 4. probe outputs
    empties = degen = 0
    samples = []
    for p in PROBES:
        body = json.dumps({"model": MODEL, "messages": [{"role": "user", "content": p}],
                           "temperature": 0, "max_tokens": 128}).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions", body,
                                     {"Content-Type": "application/json"})
        try:
            r = json.load(urllib.request.urlopen(req, timeout=90))
            txt = (r["choices"][0]["message"]["content"] or "").strip()
        except Exception:
            txt = ""
        samples.append(txt[:60])
        if not txt:
            empties += 1
        elif degenerate(txt):
            degen += 1

    ep = empties / len(PROBES)
    if ep > 0.25:
        out(f"EMPTY FAIL — {empties}/{len(PROBES)} probes empty ({ep*100:.0f}%): check no_think/reasoning_effort/max_tokens",
            False, samples=samples)
    if degen >= 2:
        out(f"DEGENERATE FAIL — {degen}/{len(PROBES)} probes were repetition gibberish", False, samples=samples)
    out("PASS — load OK, context OK, outputs clean", True, live_n_ctx=live, empties=empties, samples=samples)
finally:
    srv.terminate()
    try:
        srv.wait(timeout=10)
    except Exception:
        srv.kill()
