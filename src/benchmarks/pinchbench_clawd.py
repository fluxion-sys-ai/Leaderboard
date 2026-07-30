"""PinchBench-Clawd (single-turn) — Agentic / personal-task dimension.

Real personal-agent tasks: reading files, writing blog posts, triaging emails,
market research, calendar events. Each task's reference answer shows the CORRECT
tool call — we extract the model's <tool_call>, and score judge-free on:
  1. tool NAME match (did it pick the right action?)
  2. key ARG match (e.g. right filename, right recipient) — with the extracted
     args reported so failures are diagnosable

Categories = task types (calendar, blog, email...) so we get a per-category split.

Source: hirundo-io/pinchbench-clawd-single-turn (23 task types, 1218 paraphrases).
"""
from __future__ import annotations
import json
import re
from collections import defaultdict

from datasets import load_dataset

from .base import Benchmark, Task

_TOOLCALL = re.compile(r"<tool_call>\s*(\{.*?\})\s*</tool_call>", re.S)


def _parse_tool_calls(text: str) -> list[dict]:
    """Extract ALL tool calls a model emitted — from <tool_call> tags AND bare JSON
    objects (many models emit `{"name":..,"arguments":..}` with no wrapper). Uses a
    JSON scanner so nested argument objects (braces) are handled correctly."""
    calls: list[dict] = []
    for raw in _TOOLCALL.findall(text):          # 1) wrapped <tool_call> blocks
        try:
            o = json.loads(raw)
            if isinstance(o, dict) and "name" in o:
                calls.append(o)
        except json.JSONDecodeError:
            pass
    dec = json.JSONDecoder()                      # 2) bare JSON objects anywhere in the text
    i = 0
    while i < len(text):
        c = text.find("{", i)
        if c < 0:
            break
        try:
            o, end = dec.raw_decode(text, c)
            if isinstance(o, dict) and "name" in o and o not in calls:
                calls.append(o)
            i = end
        except json.JSONDecodeError:
            i = c + 1
    return calls


def _key_args_match(gold_args: dict, pred_args: dict) -> bool:
    """Do the model's args cover the important keys? (paths/filenames must match; other
    args must be present, but we don't require exact-value equality for free-text.)"""
    if not gold_args:
        return True
    for k, gv in gold_args.items():
        if k not in pred_args:
            return False
        # for path-like args (filenames, dirs) require exact match — that's the whole point
        if k in ("path", "filename", "file", "directory", "dir") and str(pred_args[k]) != str(gv):
            return False
    return True


class PinchBenchClawd(Benchmark):
    name = "pinchbench_clawd"
    dimension = "Agentic"

    def load(self) -> list[Task]:
        ds_cfg = self.cfg["dataset"]
        ds = load_dataset(ds_cfg["repo"], split=ds_cfg["split"], revision=self.cfg.get("revision"))
        # stratify per task_id: sample a few paraphrases per type instead of many of one type
        by_type: dict[str, list] = defaultdict(list)
        for row in ds:
            by_type[row["task_id"]].append(row)
        tasks: list[Task] = []
        per_type_cap = self.cfg.get("per_type", 5)      # ~5 paraphrases per task type
        for tid, rows in sorted(by_type.items()):
            for i, row in enumerate(rows[:per_type_cap]):
                gold_calls = _parse_tool_calls(row["answer"])
                if not gold_calls:                       # skip acknowledgment-only tasks (no tool call to score)
                    continue
                gold = gold_calls[0]                      # the reference's (single) correct call
                tasks.append(Task(
                    task_id=f"{tid}#{i}",
                    prompt=row["question"],
                    meta={"system": row["system_prompt"], "gold_tool": gold["name"],
                          "gold_args": gold.get("arguments", {}) or {},
                          "category": tid.split("_", 2)[-1] if "_" in tid else tid},
                ))
        return tasks

    def build_messages(self, task: Task) -> list[dict]:
        return [{"role": "system", "content": task.meta["system"]},
                {"role": "user", "content": task.prompt}]

    def score(self, task: Task, output: str) -> dict:
        calls = _parse_tool_calls(output)
        if not calls:
            return {"passed": False, "pred_tool": None, "gold_tool": task.meta["gold_tool"],
                    "fail_reason": "no_tool_call"}
        gold_tool, gold_args = task.meta["gold_tool"], task.meta["gold_args"]
        # pass if ANY emitted call is the right tool with the right key args (models emit a
        # sequence of calls; "did it take the correct action anywhere" is the signal)
        for c in calls:
            if c.get("name") == gold_tool and _key_args_match(gold_args, c.get("arguments", {}) or {}):
                return {"passed": True, "pred_tool": gold_tool, "gold_tool": gold_tool, "fail_reason": None}
        names = [c.get("name") for c in calls]
        return {"passed": False, "pred_tool": names[0], "gold_tool": gold_tool,
                "fail_reason": "wrong_args" if gold_tool in names else "wrong_tool"}
