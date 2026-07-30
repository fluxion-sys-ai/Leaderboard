"""ZebraLogic benchmark — Reasoning (logic puzzles) dimension.

Einstein-style logic-grid puzzles: deduce the full grid from clues. We ask for
the completed grid as JSON and score PUZZLE-LEVEL accuracy — every cell must be
correct (the standard ZebraLogic metric). Judge-free. Category = grid size
(difficulty), so the sample stratifies across easy (2x2) → hard (6x6).

Uses WildEval/ZebraLogic (has ground-truth solutions; the allenai mirror ships
blank grids to prevent contamination).
"""
from __future__ import annotations
import json
import re

from datasets import load_dataset

from .base import Benchmark, Task


def _norm(v) -> str:
    return str(v).strip().lower()


def _extract_rows(text: str) -> list | None:
    """Pull {"rows": [[...], ...]} out of the model's reply."""
    t = re.sub(r"```(?:json)?|```", "", text)
    # find the JSON object containing "rows"
    m = re.search(r"\{.*\"rows\".*\}", t, flags=re.S)
    if not m:
        return None
    try:
        return json.loads(m.group(0)).get("rows")
    except (json.JSONDecodeError, AttributeError):
        return None


class ZebraLogic(Benchmark):
    name = "zebralogic"
    dimension = "Reasoning"

    def load(self) -> list[Task]:
        ds = load_dataset("WildEval/ZebraLogic", "grid_mode",
                          split=self.cfg["dataset"].get("split", "test"),
                          revision=self.cfg.get("revision"))
        return [Task(task_id=row["id"], prompt=row["puzzle"],
                     meta={"header": row["solution"]["header"],
                           "rows": row["solution"]["rows"],
                           "category": row["size"]})
                for row in ds]

    def build_messages(self, task: Task) -> list[dict]:
        cols = ", ".join(task.meta["header"])
        return [{"role": "user",
                 "content": task.prompt + "\n\nSolve the puzzle. Output ONLY a JSON object "
                            f'{{"rows": [[...], ...]}} where each row lists, in order, the '
                            f"values for these columns: {cols}. Fill every cell."}]

    def score(self, task: Task, output: str) -> dict:
        pred = _extract_rows(output)
        gold = task.meta["rows"]
        if pred is None:
            return {"passed": False, "fail_reason": "no_grid_parsed"}
        try:
            if len(pred) != len(gold):
                return {"passed": False, "fail_reason": "wrong_shape"}
            for pr, gr in zip(pred, gold):
                if [_norm(x) for x in pr] != [_norm(x) for x in gr]:
                    return {"passed": False, "fail_reason": "wrong_cells"}
        except (TypeError, ValueError):
            return {"passed": False, "fail_reason": "malformed_grid"}
        return {"passed": True, "fail_reason": None}
