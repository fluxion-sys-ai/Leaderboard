"""Evaluator registry (judge-free only, v1)."""
from .base import Evaluator
from .ifeval_eval import IFEvalEvaluator

EVALUATORS = {
    "ifeval": IFEvalEvaluator,
}

__all__ = ["EVALUATORS", "Evaluator", "IFEvalEvaluator"]
