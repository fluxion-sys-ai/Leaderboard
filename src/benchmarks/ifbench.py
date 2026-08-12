"""IFBench benchmark — Instruction-Following (Ai2's harder successor to IFEval).

Pulls allenai/IFBench_test from HuggingFace, turns each row into a Task, and grades
with the judge-free IFBenchEvaluator (which reuses IFBench's own 58 verifier types).
Same shape as ifeval.py; the only differences are the dataset and evaluator, plus
carrying `prompt` in meta (some IFBench instructions verify against the prompt).
"""
from __future__ import annotations

from datasets import load_dataset

from .base import Benchmark, Task, wilson_ci
from ..evaluators.ifbench_eval import IFBenchEvaluator


class IFBench(Benchmark):
    name = "ifbench"
    dimension = "Instruction-Following"

    def __init__(self, cfg: dict):
        super().__init__(cfg)
        self._eval = IFBenchEvaluator()

    def load(self) -> list[Task]:
        ds_cfg = self.cfg["dataset"]
        ds = load_dataset(ds_cfg["repo"], split=ds_cfg["split"], revision=self.cfg.get("revision"))
        tasks = []
        for row in ds:
            tasks.append(Task(
                task_id=str(row["key"]),
                prompt=row["prompt"],
                meta={"instruction_id_list": row["instruction_id_list"],
                      "kwargs": row["kwargs"],
                      "prompt": row["prompt"]},   # IFBench verifiers may reference the prompt
            ))
        return tasks

    def score(self, task: Task, output: str) -> dict:
        return self._eval.score(output, task.meta)

    def aggregate(self, per_task: list[dict]) -> dict:
        from collections import defaultdict
        n = len(per_task)
        strict = sum(1 for r in per_task if r.get("passed"))
        instr_pass = sum(r.get("instr_pass", 0) for r in per_task)
        instr_total = sum(r.get("instr_total", 0) for r in per_task)
        checked = instr_total
        unsupported = sum(len(r.get("unsupported", [])) for r in per_task)
        by_type: dict = defaultdict(lambda: [0, 0])
        for r in per_task:
            for iid, ok in r.get("by_instruction", []):
                by_type[iid][1] += 1
                by_type[iid][0] += int(ok)
        return {
            "metric": "ifbench_strict_accuracy",
            "score": round(strict / n, 4) if n else 0.0,
            "ci95": wilson_ci(strict, n),
            "instruction_accuracy": round(instr_pass / checked, 4) if checked else 0.0,
            "n": n,
            "coverage": round(checked / (checked + unsupported), 4) if (checked + unsupported) else 0.0,
            "by_instruction_type": {
                iid: {"acc": round(p / t, 4), "n": t}
                for iid, (p, t) in sorted(by_type.items())
            },
        }
