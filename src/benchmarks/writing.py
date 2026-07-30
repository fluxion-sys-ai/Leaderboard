"""Writing benchmark — Writing dimension (the one JUDGE-BASED benchmark).

Open-ended writing/instruction prompts (AlpacaEval). Quality can't be scored by
exact-match, so this is the one dimension that needs an LLM judge. It works in
two steps:
  1. This module GENERATES responses in the normal grid (score() defers).
  2. `judge_writing.py` runs a separate pass: a judge model rates each response
     1-10, and the score becomes mean-rating / 10.

Clearly marked judge-based so it's never confused with the judge-free dimensions.
"""
from __future__ import annotations

import json

from huggingface_hub import hf_hub_download

from .base import Benchmark, Task


class Writing(Benchmark):
    name = "writing"
    dimension = "Writing"

    def load(self) -> list[Task]:
        # alpaca_eval ships a dataset SCRIPT (unsupported by datasets>=3) plus a
        # plain alpaca_eval.json — read the json directly (same trick as LiveCodeBench).
        path = hf_hub_download("tatsu-lab/alpaca_eval", "alpaca_eval.json", repo_type="dataset")
        data = json.load(open(path))
        return [Task(task_id=f"writing-{i}", prompt=row["instruction"], meta={})
                for i, row in enumerate(data)]

    def score(self, task: Task, output: str) -> dict:
        # Deferred: real scoring happens in the judge pass. Store nothing to grade here.
        return {"passed": None, "judge_pending": True}

    def aggregate(self, per_task: list[dict]) -> dict:
        # Placeholder until the judge pass runs; judge_writing.py overwrites this cell.
        return {"metric": "writing_judge_1to10", "score": None,
                "n": len(per_task), "judge_pending": True}
