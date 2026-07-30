"""IFEval benchmark — Instruction-Following dimension.

Pulls google/IFEval from HuggingFace (cached, never vendored), turns each row
into a Task, and grades responses with the judge-free IFEvalEvaluator.

Reference implementation for the whole repo: every other benchmark copies this
shape (load / build_messages / score / aggregate).
"""
from __future__ import annotations

from datasets import load_dataset

from .base import Benchmark, Task, wilson_ci
from ..evaluators.ifeval_eval import IFEvalEvaluator


class IFEval(Benchmark):
    name = "ifeval"
    dimension = "Instruction-Following"

    def __init__(self, cfg: dict):
        super().__init__(cfg)
        self._eval = IFEvalEvaluator()

    def load(self) -> list[Task]:
        ds_cfg = self.cfg["dataset"]
        ds = load_dataset(ds_cfg["repo"], split=ds_cfg["split"], revision=self.cfg.get("revision"))
        tasks = []
        for row in ds:
            tasks.append(Task(
                task_id=str(row["key"]),
                prompt=row["prompt"],
                # everything score() needs is carried in meta — no re-loading later
                meta={"instruction_id_list": row["instruction_id_list"],
                      "kwargs": row["kwargs"]},
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
        # per-instruction-TYPE splits (a prompt has several; group at instruction level)
        by_type: dict = defaultdict(lambda: [0, 0])   # iid -> [passed, total]
        for r in per_task:
            for iid, ok in r.get("by_instruction", []):
                by_type[iid][1] += 1
                by_type[iid][0] += int(ok)
        return {
            "metric": "ifeval_strict_accuracy",
            "score": round(strict / n, 4) if n else 0.0,       # headline: prompt-level strict
            "ci95": wilson_ci(strict, n),
            "instruction_accuracy": round(instr_pass / checked, 4) if checked else 0.0,
            "n": n,
            "coverage": round(checked / (checked + unsupported), 4) if (checked + unsupported) else 0.0,
            "by_instruction_type": {
                iid: {"acc": round(p / t, 4), "n": t}
                for iid, (p, t) in sorted(by_type.items())
            },
        }
