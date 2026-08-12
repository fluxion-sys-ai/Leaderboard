"""IFBench scorer — Ai2's expanded verifiable instruction-following.

IFBench (allenai/IFBench) is IFEval's harder successor: 58 instruction types,
many held out from IFEval to test genuine generalization rather than overfit.
Same task shape as IFEval (prompt + instruction_id_list + kwargs), so this mirrors
ifeval_eval.py exactly — EXCEPT it reuses IFBench's OWN verifier classes
(instructions_registry) instead of reimplementing the checks. That keeps our
scores on Ai2's scale (their published numbers) and gives us all 58 types for free.

The IFBench repo is imported from $IFBENCH_DIR (default ~/IFBench). Instruction ids
we can't import/verify are recorded as "unsupported" so coverage stays honest —
never silently counted as passed.

Return contract is identical to IFEvalEvaluator.score() so IFBench reuses the same
Benchmark.aggregate().
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

from .base import Evaluator

IFBENCH_DIR = os.environ.get("IFBENCH_DIR", str(Path.home() / "IFBench"))
if IFBENCH_DIR not in sys.path:
    sys.path.insert(0, IFBENCH_DIR)

try:
    import instructions_registry as _reg  # from the IFBench repo
    _DICT = _reg.INSTRUCTION_DICT
    _IMPORT_ERR = None
except Exception as exc:                  # missing repo/deps → all unsupported (honest)
    _DICT = None
    _IMPORT_ERR = exc


class IFBenchEvaluator(Evaluator):
    def score(self, output: str, meta: dict) -> dict:
        ids = meta["instruction_id_list"]
        kwargs = meta["kwargs"]
        prompt = meta.get("prompt", "")

        if _DICT is None:
            # IFBench not importable — cannot verify anything; keep coverage honest.
            return {"passed": False, "instr_pass": 0, "instr_total": 0,
                    "unsupported": list(ids), "by_instruction": []}

        results, unsupported, by_instruction = [], [], []
        for iid, kw in zip(ids, kwargs):
            cls = _DICT.get(iid)
            if cls is None:
                unsupported.append(iid)          # instruction type we don't have
                continue
            try:
                instruction = cls(iid)
                clean = {k: v for k, v in kw.items() if v is not None}
                instruction.build_description(**clean)
                # Some instructions reference the original prompt (mirrors IFBench's
                # test_instruction_following_strict).
                args = instruction.get_instruction_args()
                if args and "prompt" in args:
                    instruction.build_description(prompt=prompt)
                ok = bool(output and output.strip() and instruction.check_following(output))
            except Exception:
                ok = False                        # malformed/uncheckable response fails
            results.append(ok)
            by_instruction.append((iid, ok))

        total = len(results)
        return {
            # STRICT: full pass requires ALL instructions checked AND satisfied.
            "passed": total > 0 and not unsupported and all(results),
            "instr_pass": sum(results),
            "instr_total": total,
            "unsupported": unsupported,
            "by_instruction": by_instruction,
        }
