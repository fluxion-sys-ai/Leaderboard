"""The benchmark interface — the glue between a dataset and a score.

A benchmark knows three things and nothing about models or engines:
  1. load()          -> the list of tasks (pulled from HF, cached locally)
  2. build_messages()-> turn one task into a chat prompt for the model
  3. score()         -> turn (task, model output) into a per-task result dict

The runner drives generation; the evaluator lives inside score(). This keeps
"how do I prompt X" and "how do I grade X" together, where they belong, so
adding a benchmark is a single new file — never an edit to the CLI.
"""
from __future__ import annotations
import abc
import math
from dataclasses import dataclass


def wilson_ci(k: int, n: int, z: float = 1.96) -> list[float]:
    """95% Wilson score interval for a pass rate k/n — the honest error bar.

    Small benchmarks are noisy (AIME n=30 -> ~±16 pts); this reports that
    uncertainty instead of hiding it behind a bare number. Deterministic-greedy
    friendly: it measures finite-question-set variance, which is all that's left
    at temperature 0 (repeats can't shrink it — only more questions can).
    """
    if n == 0:
        return [0.0, 0.0]
    p = k / n
    d = 1 + z * z / n
    center = (p + z * z / (2 * n)) / d
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return [round(center - half, 4), round(center + half, 4)]


@dataclass
class Task:
    task_id: str        # stable id, used for the resume cache + result rows
    prompt: str         # the user-facing instruction
    meta: dict          # anything score() needs later (constraints, answers, ...)


class Benchmark(abc.ABC):
    name: str           # matches the key in benchmarks.yaml + the results filename

    def __init__(self, cfg: dict):
        self.cfg = cfg  # this benchmark's block from benchmarks.yaml

    @abc.abstractmethod
    def load(self) -> list[Task]:
        """Pull + cache the dataset, return tasks (already sampled/pinned)."""

    def build_messages(self, task: Task) -> list[dict]:
        """Default: a single user turn. Override for few-shot / system prompts."""
        return [{"role": "user", "content": task.prompt}]

    @abc.abstractmethod
    def score(self, task: Task, output: str) -> dict:
        """Grade one output. Return {"passed": bool, ...extra fields}."""

    def aggregate(self, per_task: list[dict]) -> dict:
        """Default headline metric: fraction passed, plus per-category splits."""
        from collections import defaultdict
        n = len(per_task)
        passed = sum(1 for r in per_task if r.get("passed"))
        out = {"metric": "accuracy", "score": round(passed / n, 4) if n else 0.0,
               "n": n, "passed": passed, "ci95": wilson_ci(passed, n)}
        # per-category breakdown when tasks carry a category
        groups: dict = defaultdict(list)
        for r in per_task:
            if r.get("category") is not None:
                groups[r["category"]].append(r)
        if groups:
            out["by_category"] = {
                c: {"score": round(sum(1 for x in rs if x.get("passed")) / len(rs), 4),
                    "n": len(rs)}
                for c, rs in sorted(groups.items())
            }
        # WHY did the failures fail? (parse error vs wrong answer vs schema violation…)
        fails = [r for r in per_task if not r.get("passed")]
        if fails:
            from collections import Counter
            out["failure_breakdown"] = dict(
                Counter(r.get("fail_reason", "unknown") for r in fails))
        return out
