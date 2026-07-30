"""HumanEval+ benchmark — Coding (code generation) dimension, floor.

The model writes a Python function from a signature + docstring; we execute it
against EvalPlus's expanded test suite (~80x more tests than vanilla HumanEval).
Judge-free (pass/fail by execution). Contamination caveat: HumanEval is in most
training sets, so treat this as a floor, not a discriminator — LiveCodeBench is
the contamination-resistant primary.
"""
from __future__ import annotations
import re

from datasets import load_dataset

from .base import Benchmark, Task
from ..evaluators.code_exec import run_program


def _extract_code(text: str) -> str:
    """Pull the Python code out of the model's reply (prefer a fenced block).

    Consume only the language tag + one newline after the opening fence — NOT the
    code's own leading indentation (which `\\s*` would wrongly strip).
    """
    blocks = re.findall(r"```(?:python)?[ \t]*\n?(.*?)```", text, flags=re.S)
    return (blocks[-1] if blocks else text).rstrip()


class HumanEvalPlus(Benchmark):
    name = "humaneval"
    dimension = "Coding"

    def load(self) -> list[Task]:
        ds_cfg = self.cfg["dataset"]
        ds = load_dataset(ds_cfg["repo"], split=ds_cfg["split"], revision=self.cfg.get("revision"))
        return [Task(task_id=row["task_id"], prompt=row["prompt"],
                     meta={"test": row["test"], "entry_point": row["entry_point"],
                           "signature_prompt": row["prompt"]})
                for row in ds]

    def build_messages(self, task: Task) -> list[dict]:
        return [{"role": "user",
                 "content": "Complete this Python function. Return the full function "
                            f"in a ```python code block.\n\n{task.prompt}"}]

    def score(self, task: Task, output: str) -> dict:
        code = _extract_code(output)
        # if the model returned only a body (no def), prepend the signature prompt
        if f"def {task.meta['entry_point']}" not in code:
            code = task.meta["signature_prompt"] + "\n" + code
        program = f"{code}\n\n{task.meta['test']}\n\ncheck({task.meta['entry_point']})\n"
        passed, reason = run_program(program)
        return {"passed": passed, "fail_reason": None if passed else reason}
