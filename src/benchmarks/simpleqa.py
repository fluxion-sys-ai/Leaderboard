"""SimpleQA — Factuality dimension (fact recall + calibration).

Short, fact-seeking questions with a single verifiable answer. The point isn't just
"does it know the fact" (MMLU-Pro covers knowledge) but "does it ADMIT when it doesn't
know instead of hallucinating" — so grading has THREE outcomes: correct / incorrect /
not-attempted. That calibration signal is what nothing else in the suite captures.

JUDGE-BASED (like writing): score() here returns judge_pending; the real grade comes
from judge_simpleqa.py, which asks DeepSeek-Chat-v3.1 to classify each answer against the
gold. Reported: accuracy (correct/total) plus not_attempted rate. Grading is objective
classification (is "1998" the right year?), not subjective quality — reproducible at temp 0.

Source: google/simpleqa-verified (the cleaned 1000-question set).
"""
from __future__ import annotations

from datasets import load_dataset

from .base import Benchmark, Task


class SimpleQA(Benchmark):
    name = "simpleqa"
    dimension = "Factuality"

    def load(self) -> list[Task]:
        ds = load_dataset(self.cfg["dataset"]["repo"],
                          split=self.cfg["dataset"].get("split", "eval"),
                          revision=self.cfg.get("revision"))
        return [Task(
            task_id=f"simpleqa-{row.get('original_index', i)}",
            prompt=row["problem"],
            meta={"gold": row["answer"], "category": row.get("topic", "general")},
        ) for i, row in enumerate(ds)]

    def build_messages(self, task: Task) -> list[dict]:
        # Plain question; the calibration signal depends on NOT nudging it to always answer.
        return [{"role": "user", "content": task.prompt}]

    def score(self, task: Task, output: str) -> dict:
        # graded externally by judge_simpleqa.py (deepseek CORRECT/INCORRECT/NOT_ATTEMPTED)
        return {"passed": None, "judge_pending": True}

    def aggregate(self, per_task: list[dict]) -> dict:
        return {"metric": "simpleqa_accuracy", "score": None, "judge_pending": True,
                "n": len(per_task)}
