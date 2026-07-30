"""BABILong benchmark — Long-context dimension.

bAbI reasoning facts are hidden inside a long distractor context; the model must
find the relevant facts and answer a short question. The point is LENGTH SCALING —
does accuracy hold as the context grows — so the category is the context length
(0k → 16k), and the per-category split shows the degradation curve directly.

Judge-free: answers are single words, scored by exact/word match. Needs a large
n_ctx (see models.yaml defaults) — the 16k split won't fit in 8k context.
"""
from __future__ import annotations
import re

from datasets import load_dataset

from .base import Benchmark, Task

LENGTHS = ["0k", "4k", "16k"]          # context-length buckets (the category)
TASKS = ["qa1", "qa2"]                 # bAbI task types (single + two supporting facts)
PER = 25                               # items per (length, task)


class BABILong(Benchmark):
    name = "babilong"
    dimension = "Long-context"

    def load(self) -> list[Task]:
        tasks = []
        for length in LENGTHS:
            for qa in TASKS:
                ds = load_dataset("RMT-team/babilong", length, split=qa,
                                  revision=self.cfg.get("revision"))
                for i, row in enumerate(ds):
                    if i >= PER:
                        break
                    tasks.append(Task(
                        task_id=f"babilong-{length}-{qa}-{i}",
                        prompt=f"{row['input']}\n\n{row['question']}",
                        meta={"target": row["target"], "category": length}))
        return tasks

    def build_messages(self, task: Task) -> list[dict]:
        return [{"role": "user", "content": task.prompt + "\n\nAnswer with a single word."}]

    def score(self, task: Task, output: str) -> dict:
        gold = str(task.meta["target"]).strip().lower()
        # single-word answer: correct if the gold word appears in the response
        ok = re.search(rf"\b{re.escape(gold)}\b", output.lower()) is not None
        return {"passed": ok, "gold": gold,
                "fail_reason": None if ok else "wrong_or_missing"}
