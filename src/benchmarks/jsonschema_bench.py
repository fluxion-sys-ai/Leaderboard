"""JSONSchemaBench — Instruction-Following (structured output) dimension.

Given a JSON Schema, the model must emit a JSON object that VALIDATES against it.
This is the reliability signal edge/tool-use cares about: small models often emit
almost-valid JSON that breaks downstream parsing.

Judge-free: we parse the model's output and validate it with the `jsonschema`
library. Loaded across difficulty tiers (category = tier) so the sample is
stratified and gets a per-difficulty breakdown.
"""
from __future__ import annotations
import json
import re

from datasets import load_dataset
import jsonschema

from .base import Benchmark, Task

# difficulty tiers → used as the category for stratified sampling + splits
TIERS = ["Github_trivial", "Github_easy", "Github_medium", "Github_hard"]


def _extract_json(text: str) -> str | None:
    """Pull the JSON object out of the model's reply (strip fences / prose)."""
    t = re.sub(r"```(?:json)?|```", "", text).strip()
    start = t.find("{")
    end = t.rfind("}")
    return t[start:end + 1] if start != -1 and end > start else None


class JSONSchemaBench(Benchmark):
    name = "jsonschemabench"
    dimension = "Instruction-Following"

    def load(self) -> list[Task]:
        split = self.cfg["dataset"].get("split", "test")
        tasks = []
        for tier in TIERS:
            ds = load_dataset(self.cfg["dataset"]["repo"], tier, split=split,
                              revision=self.cfg.get("revision"))
            for row in ds:
                tasks.append(Task(
                    task_id=row["unique_id"],
                    prompt=("Generate a single JSON object that strictly conforms to this "
                            f"JSON Schema. Output only the JSON.\n\n{row['json_schema']}"),
                    meta={"schema": json.loads(row["json_schema"]), "category": tier},
                ))
        return tasks

    def score(self, task: Task, output: str) -> dict:
        raw = _extract_json(output)
        if raw is None:
            return {"passed": False, "fail_reason": "no json found"}
        try:
            instance = json.loads(raw)
        except json.JSONDecodeError:
            return {"passed": False, "fail_reason": "invalid json"}
        try:
            jsonschema.validate(instance, task.meta["schema"])
            return {"passed": True}
        except jsonschema.ValidationError:
            return {"passed": False, "fail_reason": "schema violation"}
        except jsonschema.SchemaError:
            return {"passed": False, "fail_reason": "bad schema"}   # dataset schema issue
