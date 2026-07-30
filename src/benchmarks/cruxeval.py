"""CruxEval benchmark — Coding (code reasoning) dimension.

Output prediction: given a Python function and an input, predict what it returns.
Tests whether the model can *trace execution*, distinct from writing code.

Judge-free and NO sandbox needed: the dataset ships the gold output, so we just
compare the model's predicted value to it (structural equality via literal_eval,
falling back to normalized string match). We never execute model or dataset code.
"""
from __future__ import annotations
import ast
import re

from datasets import load_dataset

from .base import Benchmark, Task


def _norm(v: str) -> object:
    """Best-effort parse to a Python value for structural comparison."""
    v = v.strip()
    try:
        return ast.literal_eval(v)
    except Exception:
        return v.strip("'\" ")


def _extract_pred(text: str) -> str | None:
    """Pull the predicted output value from the model's response."""
    # after '==' (CruxEval's assert style) or 'output is'
    m = re.findall(r"==\s*(.+)", text) or re.findall(r"output\s*(?:is|:)?\s*(.+)", text, flags=re.I)
    if m:
        return m[-1].strip().rstrip(".")
    # else last non-empty line (often the bare value / a code block line)
    lines = [l.strip(" `") for l in text.strip().splitlines() if l.strip(" `")]
    return lines[-1] if lines else None


class CruxEval(Benchmark):
    name = "cruxeval"
    dimension = "Coding"

    def load(self) -> list[Task]:
        ds_cfg = self.cfg["dataset"]
        ds = load_dataset(ds_cfg["repo"], split=ds_cfg["split"], revision=self.cfg.get("revision"))
        tasks = []
        for row in ds:
            prompt = (f"{row['code']}\n\n"
                      f"What does the call `f({row['input']})` return? "
                      f"Give only the exact output value.")
            tasks.append(Task(task_id=row["id"], prompt=prompt,
                              meta={"gold": row["output"]}))
        return tasks

    def score(self, task: Task, output: str) -> dict:
        pred = _extract_pred(output)
        gold = task.meta["gold"]
        ok = False
        if pred is not None:
            try:
                ok = _norm(pred) == _norm(gold)
            except Exception:
                ok = pred.strip() == gold.strip()
        reason = None if ok else ("no_answer_parsed" if pred is None else "wrong_trace")
        return {"passed": ok, "pred": pred, "gold": gold, "fail_reason": reason}
