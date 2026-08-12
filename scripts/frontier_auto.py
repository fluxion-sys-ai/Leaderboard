#!/usr/bin/env python3
"""frontier_auto.py — automated, self-healing, overnight-safe runner for the
frontier full-precision tab (OpenRouter, direct-API benches).

Flow per (model, bench): SMOKE (--limit) -> GATE -> if off, try a known
param-preserving fix and re-smoke once -> if still off, write a diagnostic
marker and SKIP (never stall) -> if sane, FULL run -> ANOMALY CHECK the full
score against real expected ranges (from the board's history / vendor targets);
anomalies are flagged for AI diagnosis but never block the sweep.

Designed to run detached overnight:
  * Resumable — completed tasks are cached in results/raw, so a restart
    continues where it left off.
  * Heartbeat — writes results/frontier_auto_heartbeat.json every step so a
    watchdog (and the AI-in-the-loop) can see liveness + progress.
  * Never stalls — every model/bench is wrapped; one failure is logged and
    skipped, the sweep marches on.
  * AI hook — anything it can't auto-fix is written to diagnostics/<...>.json
    with the evidence a diagnosing agent needs (log tail, scores, provider).

Recommended sampling params are read verbatim from models_full.yaml and NEVER
changed. Auto-fixes only touch non-sampling knobs (reasoning depth, headroom).

Usage:
  OPENROUTER_API_KEY=$(cat .openrouter_key) \
    python3 scripts/frontier_auto.py --benchmarks ifeval aime2026 --smoke-limit 5
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RESULTS = REPO_ROOT / "results" / "scored"
RAW = REPO_ROOT / "results" / "raw"
MODELS_FULL = REPO_ROOT / "configs" / "models_full.yaml"
DIAG_DIR = REPO_ROOT / "results" / "diagnostics"
HEARTBEAT = REPO_ROOT / "results" / "frontier_auto_heartbeat.json"

MODEL_ORDER = [
    "muse-glimmer-30b-full",
    "qwen3.6-27b-full",
    "qwen3.6-35b-a3b-full",
    "gemma-4-31b-full",
]
DEFAULT_BENCHES = ["ifeval", "aime2026"]

COVERAGE_MIN = 0.90
BROKEN_FLOORS = {"mmlu_pro": 0.10}

# Expected full-run ranges for a frontier-30B, anchored to the board's history
# (HANDOFF.md) + vendor targets. A full score BELOW `low` is "weird/off" and gets
# flagged for AI diagnosis (not a hard skip — could be a genuinely weak model).
EXPECTED = {
    "ifeval":   {"low": 0.45, "note": "frontier instruction-following ~0.7-0.9; <0.45 usually truncation/format"},
    "aime2026": {"low": 0.15, "note": "frontier reasoning models clear ~0.4+; <0.15 usually reasoning-truncation (answer lost after max_tokens), not skill"},
}

_SERVED_RE = re.compile(r"served by '([^']+)'")
_THINKING_REJECT_RE = re.compile(r'Thinking level "([^"]+)" is not supported', re.I)
_TRUNCATED_RE = re.compile(r"TRUNCATED \(finish_reason=length")
_BILLING_RE = re.compile(r"402|billing error|insufficient balance|out of credits", re.I)


def log(msg: str) -> None:
    print(f"[frontier-auto] {msg}", flush=True)


def load_models() -> dict:
    import yaml
    cfg = yaml.safe_load(MODELS_FULL.read_text("utf-8"))
    return {m["name"]: m for m in cfg.get("models", [])}


def expected_providers(model_cfg: dict):
    prov = model_cfg.get("provider", {}) or {}
    quants = prov.get("quantizations", [])
    precision = "bf16" if "bf16" in quants else ("fp8" if "fp8" in quants else "?")
    order = prov.get("order")
    if precision == "bf16" and order:
        return set(order), precision
    return None, precision


def heartbeat(state: dict) -> None:
    state["ts"] = int(time.time())
    try:
        HEARTBEAT.write_text(json.dumps(state, indent=2), "utf-8")
    except OSError:
        pass


def write_diagnostic(model: str, bench: str, kind: str, detail: str, out: str) -> None:
    """Drop a structured marker for the AI-in-the-loop watchdog to pick up."""
    DIAG_DIR.mkdir(parents=True, exist_ok=True)
    rec = {
        "ts": int(time.time()), "model": model, "bench": bench, "kind": kind,
        "detail": detail, "resolved": False,
        "log_tail": "\n".join(out.strip().splitlines()[-25:]),
        "hint": "AI: diagnose using repo docs (HANDOFF.md/RECOMMENDED_PARAMS.md) + the log tail; "
                "apply a param-PRESERVING fix (reasoning depth, headroom, ctx, retry) and re-run this cell.",
    }
    (DIAG_DIR / f"{model}__{bench}__{int(time.time())}.json").write_text(
        json.dumps(rec, indent=2), "utf-8")
    log(f"  ⚑ diagnostic written [{model}/{bench}] kind={kind}")


def run_cell(model: str, bench: str, limit, extra_env=None):
    cmd = [sys.executable, str(REPO_ROOT / "run_benchmark.py"),
           "--models-config", str(MODELS_FULL), "--models", model, "--benchmarks", bench]
    if limit:
        cmd += ["--limit", str(limit)]
    import os
    env = {**os.environ, **(extra_env or {})}
    proc = subprocess.run(cmd, cwd=str(REPO_ROOT), capture_output=True, text=True, env=env)
    out = proc.stdout + "\n" + proc.stderr
    rp = RESULTS / model / f"{bench}.json"
    result = None
    if rp.exists():
        try:
            result = json.loads(rp.read_text("utf-8"))
        except json.JSONDecodeError:
            result = None
    return result, out


def gate(model, bench, result, out, allowed):
    """(passed, reason). Structural sanity only — 'is this a valid run'."""
    if _BILLING_RE.search(out) and (result is None or result.get("score") in (None, 0.0)):
        return False, "BILLING/402 — OpenRouter key out of credits"
    if result is None:
        return False, "no result JSON (cell raised or produced nothing)"
    if result.get("score") is None:
        return False, "score is null"
    cov = result.get("coverage")
    if cov is not None and cov < COVERAGE_MIN:
        return False, f"coverage {cov:.2f} < {COVERAGE_MIN} (API errors dropped tasks)"
    if (result.get("perf", {}) or {}).get("mean_completion_tokens", 0) == 0:
        return False, "mean_completion_tokens == 0 (degenerate/no generation)"
    floor = BROKEN_FLOORS.get(bench)
    if floor is not None and result["score"] < floor:
        return False, f"score {result['score']} below random floor {floor} (broken output)"
    served = (_SERVED_RE.search(out) or [None, None])[1] if _SERVED_RE.search(out) else None
    if allowed is not None and served is not None and served not in allowed:
        return False, f"served '{served}' NOT in pinned bf16 set {sorted(allowed)} (precision downgrade)"
    cov_s = f"{cov:.2f}" if cov is not None else "n/a"
    return True, f"score={result['score']} coverage={cov_s} served={served or 'UNVERIFIED-cached'}"


def anomaly_check(bench, score):
    """Is a *sane-looking* full score still weird vs expected? (soft flag)"""
    exp = EXPECTED.get(bench)
    if exp and score is not None and score < exp["low"]:
        return f"score {score} < expected low {exp['low']} — {exp['note']}"
    return None


def clear_cell_cache(model, bench):
    for p in (RAW / model / f"{bench}.jsonl", RESULTS / model / f"{bench}.json"):
        try:
            p.unlink()
        except OSError:
            pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="*")
    ap.add_argument("--benchmarks", nargs="*", default=DEFAULT_BENCHES)
    ap.add_argument("--smoke-limit", type=int, default=5)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    models = load_models()
    order = [n for n in (args.models or MODEL_ORDER) if n in models]
    state = {"phase": "start", "order": order, "benches": args.benchmarks,
             "done": [], "flagged": [], "skipped": []}
    heartbeat(state)

    for name in order:
        mcfg = models[name]
        allowed, precision = expected_providers(mcfg)
        log(f"=== {name} ({precision}; pin={sorted(allowed) if allowed else 'any'}) ===")
        for bench in args.benchmarks:
            cell = f"{name}/{bench}"
            state["phase"] = f"smoke {cell}"; heartbeat(state)
            try:
                log(f"  smoke: {cell} (limit={args.smoke_limit})")
                result, out = run_cell(name, bench, args.smoke_limit)

                # --- known param-preserving auto-fixes, then ONE re-smoke ---
                fixed = None
                tj = _THINKING_REJECT_RE.search(out)
                if _BILLING_RE.search(out):
                    write_diagnostic(name, bench, "billing", "402/insufficient credits", out)
                    state["skipped"].append(cell); heartbeat(state)
                    log(f"  ✗ {cell}: billing/402 — skipping (needs credit top-up)")
                    continue
                ok, reason = gate(name, bench, result, out, allowed)
                if not ok and _TRUNCATED_RE.search(out):
                    # truncation is handled by the runner's reasoning floor; a
                    # persistent truncation means the floor needs raising -> flag.
                    fixed = "truncation"
                if not ok and tj:
                    fixed = f"thinking:{tj.group(1)}"
                if not ok and fixed:
                    log(f"  ↻ auto-fix [{cell}]: {fixed} — clearing cache & re-smoking once")
                    clear_cell_cache(name, bench)
                    result, out = run_cell(name, bench, args.smoke_limit)
                    ok, reason = gate(name, bench, result, out, allowed)

                if not ok:
                    log(f"  ✗ SMOKE OFF [{cell}]: {reason} — flag + skip, moving on")
                    write_diagnostic(name, bench, "smoke_off", reason, out)
                    state["skipped"].append(cell); heartbeat(state)
                    continue
                log(f"  ✓ smoke sane [{cell}]: {reason}")
                if args.dry_run:
                    state["done"].append(cell + ":smoke"); heartbeat(state)
                    continue

                # --- FULL run ---
                state["phase"] = f"full {cell}"; heartbeat(state)
                log(f"  full: {cell}")
                fres, fout = run_cell(name, bench, None)
                fok, freason = gate(name, bench, fres, fout, allowed)
                score = (fres or {}).get("score")
                if not fok:
                    log(f"  ✗ FULL failed [{cell}]: {freason} — flag + skip")
                    write_diagnostic(name, bench, "full_failed", freason, fout)
                    state["skipped"].append(cell); heartbeat(state)
                    continue
                anom = anomaly_check(bench, score)
                if anom:
                    log(f"  ⚠ ANOMALY [{cell}]: {anom} — kept but flagged for AI review")
                    write_diagnostic(name, bench, "anomaly", anom, fout)
                    state["flagged"].append({"cell": cell, "score": score, "why": anom})
                else:
                    log(f"  ✓ FULL done [{cell}]: {freason}")
                state["done"].append({"cell": cell, "score": score}); heartbeat(state)
            except Exception as e:  # never let one cell kill the overnight run
                log(f"  !! EXCEPTION [{cell}]: {type(e).__name__}: {str(e)[:160]} — skipping")
                write_diagnostic(name, bench, "exception", f"{type(e).__name__}: {e}", "")
                state["skipped"].append(cell); heartbeat(state)

    state["phase"] = "complete"; heartbeat(state)
    log("=" * 60)
    log("SUMMARY")
    for d in state["done"]:
        log(f"  [OK ] {d}")
    for f in state["flagged"]:
        log(f"  [FLAG] {f}")
    for s in state["skipped"]:
        log(f"  [SKIP] {s}")
    log(f"heartbeat: {HEARTBEAT}  diagnostics: {DIAG_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
