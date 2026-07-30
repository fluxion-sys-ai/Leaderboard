"""Competition-math benchmarks — Reasoning (math) dimension, contamination-free.

AIME 2026 and HMMT are fresh olympiad-style contests (released after these models'
training), so they're a clean, hard math signal that GSM8K (saturated) can't give.
Zero-shot + CoT; we extract the final answer and exact-match it. Judge-free.

One class, parameterized by dataset — registered as `aime2026` and `hmmt`.
"""
from __future__ import annotations
import re

from datasets import load_dataset

from .base import Benchmark, Task


def _norm(s: str) -> str:
    """Normalize a math answer for comparison (strip latex/space/$)."""
    s = str(s).strip().strip("$").replace(" ", "")
    m = re.search(r"\\boxed\{(.+?)\}", s)
    if m:
        s = m.group(1)
    return s.strip("$")


def _boxed(text: str) -> str | None:
    """Extract the LAST \\boxed{...}, balancing nested braces (e.g. \\frac{1}{21})."""
    idx = text.rfind("\\boxed{")
    if idx == -1:
        return None
    i, depth, out = idx + len("\\boxed{"), 1, []
    while i < len(text) and depth > 0:
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        if depth > 0:
            out.append(c)
        i += 1
    return "".join(out)


def _extract(text: str) -> str | None:
    """Pull the final answer: \\boxed{} (brace-balanced) > 'answer is X' > last integer."""
    b = _boxed(text)
    if b is not None:
        return b
    m = re.findall(r"answer\s*(?:is|=|:)?\s*\$?([^\n.$]+)", text, flags=re.I)
    if m:
        return m[-1].strip()
    nums = re.findall(r"-?\d+", text)
    return nums[-1] if nums else None


class CompetitionMath(Benchmark):
    dimension = "Reasoning"

    def load(self) -> list[Task]:
        ds = load_dataset(self.cfg["dataset"]["repo"], split=self.cfg["dataset"].get("split", "train"),
                          revision=self.cfg.get("revision"))
        tasks = []
        for i, row in enumerate(ds):
            tasks.append(Task(
                task_id=f"{self.name}-{row.get('problem_idx', i)}",
                prompt=row["problem"],
                meta={"gold": str(row["answer"]),
                      "category": row.get("problem_type")},   # HMMT has problem_type; AIME None
            ))
        return tasks

    def build_messages(self, task: Task) -> list[dict]:
        return [{"role": "user",
                 "content": task.prompt + "\n\nSolve step by step, then give the final "
                            "answer as \\boxed{...}."}]

    def score(self, task: Task, output: str) -> dict:
        pred = _extract(output)
        ok = pred is not None and _norm(pred) == _norm(task.meta["gold"])
        reason = None if ok else ("no_answer_parsed" if pred is None else "wrong_answer")
        return {"passed": ok, "pred": pred, "gold": task.meta["gold"], "fail_reason": reason}


class AIME2026(CompetitionMath):
    name = "aime2026"


class HMMT(CompetitionMath):
    name = "hmmt"
