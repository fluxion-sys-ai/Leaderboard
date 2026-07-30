"""RULER — Long-context dimension (retrieval + tracking under long context).

The standard long-context benchmark: needle-in-a-haystack variants (single/multi-key,
multi-value, multi-query), variable tracking, frequent-word extraction, and long-doc QA
— all embedded in a long synthetic context. Complements BABILong (which scales length on
reasoning); RULER stresses RETRIEVAL at a fixed long length across 13 task types.

Judge-free: the gold answer is one or more strings that must appear in the output; we
score recall (all gold strings present = pass). Category = task type, so we get a split
across niah / vt / fwe / qa. Context length is a config (4096 / 8192 / 16384); default
8192 fits our 20480 n_ctx with headroom and is already hard for edge models.

Source: simonjegou/ruler (static, pre-generated).
"""
from __future__ import annotations
import ast

from datasets import load_dataset

from .base import Benchmark, Task


def _gold_list(raw) -> list[str]:
    """The dataset stores answers as a stringified list (e.g. \"['8090293']\")."""
    if isinstance(raw, list):
        return [str(x) for x in raw]
    try:
        v = ast.literal_eval(raw)
        return [str(x) for x in v] if isinstance(v, (list, tuple)) else [str(v)]
    except (ValueError, SyntaxError):
        return [str(raw)]


class Ruler(Benchmark):
    name = "ruler"
    dimension = "Long-context"

    def load(self) -> list[Task]:
        length = str(self.cfg.get("context_length", 8192))
        ds = load_dataset(self.cfg["dataset"]["repo"], length,
                          split="test", revision=self.cfg.get("revision"))
        return [Task(
            task_id=f"{length}-{i}",
            prompt=f"{row['context']}\n\n{row['question']}\n{row['answer_prefix']}",
            meta={"gold": _gold_list(row["answer"]), "category": row["task"]},
        ) for i, row in enumerate(ds)]

    def score(self, task: Task, output: str) -> dict:
        low = output.lower()
        gold = task.meta["gold"]
        found = [g for g in gold if g.lower() in low]
        passed = len(found) == len(gold) and gold != []      # all needles recovered
        return {"passed": passed, "n_gold": len(gold), "n_found": len(found),
                "fail_reason": None if passed else "missing_needle"}
