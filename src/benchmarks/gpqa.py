"""GPQA Diamond benchmark — Reasoning / graduate-level science (phys/chem/bio).

198 expert-written, "Google-proof" multiple-choice questions. We shuffle the four
answer options DETERMINISTICALLY (so the gold letter isn't always the same slot),
let the model reason, extract its chosen letter, and exact-match. Judge-free.

Sourced from Artificial Analysis's Scientific-Reasoning category. The dataset is
GATED (auto-approve) on HF, so loading needs an authenticated token at run time.

NOTE: the column names below follow the standard `Idavidrein/gpqa` schema. The repo
is gated, so we could not pre-verify them here — confirm on the first authenticated
run (a KeyError would point at any that differ).
"""
from __future__ import annotations
import random

from datasets import load_dataset

from .base import Benchmark, Task
from ._mcq import extract_letter

_LETTERS = "ABCD"


class GPQADiamond(Benchmark):
    name = "gpqa_diamond"
    dimension = "Reasoning"

    def load(self) -> list[Task]:
        ds_cfg = self.cfg["dataset"]
        ds = load_dataset(ds_cfg["repo"], ds_cfg.get("config"),
                          split=ds_cfg["split"], revision=self.cfg.get("revision"))
        seed = self.cfg.get("seed", 42)
        tasks = []
        for i, row in enumerate(ds):
            correct = row["Correct Answer"].strip()
            options = [correct, row["Incorrect Answer 1"].strip(),
                       row["Incorrect Answer 2"].strip(), row["Incorrect Answer 3"].strip()]
            # per-question deterministic shuffle -> gold letter varies but is reproducible
            random.Random(seed + i).shuffle(options)
            gold = _LETTERS[options.index(correct)]
            lettered = "\n".join(f"({_LETTERS[j]}) {o}" for j, o in enumerate(options))
            tasks.append(Task(
                task_id=f"gpqa-{i}",
                prompt=f"{row['Question'].strip()}\n\n{lettered}",
                meta={"gold": gold, "category": row.get("High-level domain", "science")},
            ))
        return tasks

    def build_messages(self, task: Task) -> list[dict]:
        return [{"role": "user",
                 "content": task.prompt + "\n\nThink step by step, then end with "
                            "'The answer is (X)'."}]

    def score(self, task: Task, output: str) -> dict:
        pred = extract_letter(output, 4)
        ok = pred == task.meta["gold"]
        reason = None if ok else ("no_answer_parsed" if pred is None else "wrong_answer")
        return {"passed": ok, "pred": pred, "gold": task.meta["gold"], "fail_reason": reason}
