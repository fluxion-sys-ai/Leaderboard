"""MMLU-Pro benchmark — Reasoning / knowledge dimension.

Multiple-choice across 14 subjects (math, physics, law, ...). Zero-shot + CoT:
the model reasons, then we extract its chosen letter and exact-match it. Judge-free.
Each task carries meta['category'] = subject, so the sample is STRATIFIED across
subjects and the result gets a per-subject breakdown automatically.
"""
from __future__ import annotations
import string

from datasets import load_dataset

from .base import Benchmark, Task
from ._mcq import extract_letter


class MMLUPro(Benchmark):
    name = "mmlu_pro"
    dimension = "Reasoning"

    def load(self) -> list[Task]:
        ds_cfg = self.cfg["dataset"]
        ds = load_dataset(ds_cfg["repo"], split=ds_cfg["split"], revision=self.cfg.get("revision"))
        tasks = []
        for row in ds:
            opts = row["options"]
            lettered = "\n".join(f"({string.ascii_uppercase[i]}) {o}" for i, o in enumerate(opts))
            gold = string.ascii_uppercase[row["answer_index"]]
            tasks.append(Task(
                task_id=f"mmlupro-{row['question_id']}",
                prompt=f"{row['question']}\n\n{lettered}",
                meta={"gold": gold, "n_options": len(opts), "category": row["category"]},
            ))
        return tasks

    def build_messages(self, task: Task) -> list[dict]:
        return [{"role": "user",
                 "content": task.prompt + "\n\nThink step by step, then end with "
                            "'The answer is (X)'."}]

    def score(self, task: Task, output: str) -> dict:
        pred = extract_letter(output, task.meta["n_options"])
        ok = pred == task.meta["gold"]
        reason = None if ok else ("no_answer_parsed" if pred is None else "wrong_answer")
        return {"passed": ok, "pred": pred, "gold": task.meta["gold"], "fail_reason": reason}
