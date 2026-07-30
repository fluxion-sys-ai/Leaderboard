"""Evaluator interface — output in, score out.

Some dimensions score with exact-match, some with sandboxed execution, some with
constraint checks (IFEval). Each is an Evaluator so benchmarks can stay agnostic
about *how* grading happens. Judge-free evaluators only, for v1.
"""
from __future__ import annotations
import abc


class Evaluator(abc.ABC):
    @abc.abstractmethod
    def score(self, output: str, meta: dict) -> dict:
        """Grade one output against its task metadata. Returns {"passed": bool, ...}."""
