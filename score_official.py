#!/usr/bin/env python3
"""Official-scorer re-scoring — field-comparable numbers from the *reference*
implementations, run on our cached generations (CPU only, no GPU, no regen).

Our in-repo scorers (rescore_all.py) are fast + transparent but reimplemented, so
they land ~1pt off published leaderboards and aren't strictly comparable. This
script re-scores the SAME cached outputs with each benchmark's official tool:

  HumanEval  -> evalplus            (execution, pass@1 base+plus)   [WIRED]

Scoring policy (decided 2026-07-29): use an OFFICIAL package only where scoring is
HARD to reimplement comparably (code execution, AST match). Easy extract-and-match
benchmarks (MMLU-Pro, GSM8K, AIME, ZebraLogic, CruxEval, JSONSchemaBench, BABILong,
IFEval) keep their in-repo scorers — that's standard practice and diverges <1pt.
  - BFCL: bfcl_eval ships v4 data; our cache is v1 -> needs a v4 re-run to score
    officially (deferred). In-repo AST scorer used meanwhile.
  - IFEval: staying in-repo (individually-simple constraint checks; bug since fixed).

Results go to results/scored_official/<model>/<benchmark>.json — kept SEPARATE
from results/scored/ so both views coexist. Runs in the isolated scorer-env venv
(/home/ubuntu/scorer-env) that holds the pinned official deps.
"""
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent
RAW = REPO / "results" / "raw"
OUT = REPO / "results" / "scored_official"


def _extract_code(text: str) -> str:
    """Same fenced-block extraction the in-repo scorer uses, for parity."""
    blocks = re.findall(r"```(?:python)?[ \t]*\n?(.*?)```", text, flags=re.S)
    return (blocks[-1] if blocks else text).rstrip()


def _models_with(benchmark: str) -> list[str]:
    return sorted(p.parent.name for p in RAW.glob(f"*/{benchmark}.jsonl"))


# ── HumanEval via evalplus ───────────────────────────────────────────────────
def score_humaneval(model: str) -> dict:
    """Write evalplus 'solution' samples from cached output, run evalplus, parse pass@1."""
    rows = [json.loads(l) for l in open(RAW / model / "humaneval.jsonl")]
    with tempfile.TemporaryDirectory() as td:
        samples = Path(td) / "samples.jsonl"
        with open(samples, "w") as f:
            for r in rows:
                f.write(json.dumps({"task_id": r["task_id"],
                                    "solution": _extract_code(r["output"])}) + "\n")
        # evalplus sanitizes + executes against base and plus test suites
        subprocess.run([sys.executable, "-m", "evalplus.evaluate",
                        "--dataset", "humaneval", "--samples", str(samples)],
                       cwd=td, check=True, capture_output=True, text=True)
        res = json.loads(open(str(samples).replace(".jsonl", "_eval_results.json")).read())
    evals = res["eval"]
    base = sum(1 for v in evals.values() if v[0]["base_status"] == "pass") / len(evals)
    plus = sum(1 for v in evals.values()
               if v[0]["base_status"] == "pass" and v[0]["plus_status"] == "pass") / len(evals)
    return {"metric": "evalplus_pass@1", "scorer": "evalplus", "n": len(evals),
            "score": round(plus, 4), "score_base": round(base, 4)}


SCORERS = {"humaneval": score_humaneval}


def main():
    which = sys.argv[1:] or list(SCORERS)
    for benchmark in which:
        fn = SCORERS[benchmark]
        for model in _models_with(benchmark):
            try:
                out = fn(model)
            except Exception as e:
                print(f"  {benchmark}/{model}: FAILED {type(e).__name__}: {e}", flush=True)
                continue
            dst = OUT / model / f"{benchmark}.json"
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(json.dumps(out, indent=2))
            print(f"  {benchmark}/{model}: {out['score']} (base {out.get('score_base','-')}, n={out['n']})", flush=True)


if __name__ == "__main__":
    main()
