"""GSM8K benchmark — Reasoning (grade-school math) dimension.

Zero-shot + chain-of-thought (our standard protocol): the model reasons freely,
then we extract its final number and exact-match it against the gold answer.
Judge-free. Gold answers live after '####' in the dataset's answer field.
"""
from __future__ import annotations
import re

from datasets import load_dataset

from .base import Benchmark, Task

_NUM = r"-?\d+(?:\.\d+)?"


def _gold(answer: str) -> str:
    """Gold answer is the number after '####'."""
    return answer.split("####")[-1].strip().replace(",", "")


def _extract_pred(text: str) -> str | None:
    """Prefer a number after 'answer is/:'; else fall back to the last number."""
    t = text.replace(",", "")
    m = re.findall(rf"answer\s*(?:is|:)?\s*\$?({_NUM})", t, flags=re.I)
    if m:
        return m[-1]
    nums = re.findall(_NUM, t)
    return nums[-1] if nums else None


class GSM8K(Benchmark):
    name = "gsm8k"
    dimension = "Reasoning"

    def load(self) -> list[Task]:
        ds_cfg = self.cfg["dataset"]
        ds = load_dataset(ds_cfg["repo"], "main", split=ds_cfg["split"],
                          revision=self.cfg.get("revision"))
        return [Task(task_id=f"gsm8k-{i}", prompt=row["question"],
                     meta={"gold": _gold(row["answer"])})
                for i, row in enumerate(ds)]

    def build_messages(self, task: Task) -> list[dict]:
        # gentle nudge so the final answer is easy to extract — doesn't leak anything
        return [{"role": "user",
                 "content": task.prompt + "\n\nThink step by step, then end with "
                            "'The answer is <number>'."}]

    def score(self, task: Task, output: str) -> dict:
        pred = _extract_pred(output)
        gold = task.meta["gold"]
        ok = False
        if pred is not None:
            try:
                ok = abs(float(pred) - float(gold)) < 1e-4
            except ValueError:
                ok = pred == gold
        reason = None if ok else ("no_answer_parsed" if pred is None else "wrong_answer")
        return {"passed": ok, "pred": pred, "gold": gold, "fail_reason": reason}
