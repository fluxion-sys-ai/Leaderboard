"""BFCL benchmark — Agentic (tool-use / function-calling) dimension.

Berkeley Function-Calling Leaderboard (non-live AST subset). The model is given a
user request + a set of tools, and must emit the correct function call(s). We
score by AST/value match against the gold calls — judge-free.

Categories (the sub-splits) = simple / parallel / multiple / parallel_multiple,
so the per-category split shows single-call vs multi-call ability.
"""
from __future__ import annotations
import json
import re

from datasets import load_dataset

from .base import Benchmark, Task

CONFIGS = ["simple", "parallel", "multiple", "parallel_multiple"]


def _norm(v):
    """Normalize an argument value for comparison (case/space-insensitive scalars)."""
    if isinstance(v, str):
        return v.strip().lower()
    if isinstance(v, list):
        return [_norm(x) for x in v]
    if isinstance(v, dict):
        return {k: _norm(x) for k, x in v.items()}
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return v


def _gold_calls(messages: list) -> list:
    calls = []
    for m in messages:
        for tc in (m.get("tool_calls") or []):
            fn = tc["function"]
            args = fn["arguments"]
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except json.JSONDecodeError:
                    args = {}
            calls.append({"name": fn["name"], "args": args})
    return calls


def _parse_model_calls(text: str) -> list:
    """Extract a JSON array of {name, arguments} from the model's reply."""
    t = re.sub(r"```(?:json)?|```", "", text)
    m = re.search(r"\[.*\]", t, flags=re.S) or re.search(r"\{.*\}", t, flags=re.S)
    if not m:
        return []
    try:
        data = json.loads(m.group(0))
    except json.JSONDecodeError:
        return []
    if isinstance(data, dict):
        data = [data]
    out = []
    for c in data:
        if isinstance(c, dict) and "name" in c:
            out.append({"name": c["name"], "args": c.get("arguments", c.get("args", {})) or {}})
    return out


class BFCL(Benchmark):
    name = "bfcl"
    dimension = "Agentic"

    def load(self) -> list[Task]:
        tasks = []
        for cfg in CONFIGS:
            ds = load_dataset("minpeter/bfcl-v1-non-live-ast-parsed", cfg, split="train",
                              revision=self.cfg.get("revision"))
            for row in ds:
                user = next((m["content"] for m in row["messages"] if m["role"] == "user"), "")
                tools = row["tools"] if isinstance(row["tools"], str) else json.dumps(row["tools"])
                tasks.append(Task(
                    task_id=row["extra"]["id"],
                    prompt=user,
                    meta={"tools": tools, "gold": _gold_calls(row["messages"]), "category": cfg}))
        return tasks

    def build_messages(self, task: Task) -> list[dict]:
        return [{"role": "user",
                 "content": f"You can call these tools:\n{task.meta['tools']}\n\n"
                            f"User request: {task.prompt}\n\n"
                            'Respond with ONLY a JSON array of the function call(s) to make, '
                            'each as {"name": "...", "arguments": {...}}.'}]

    def _match(self, gold: dict, model_calls: list) -> bool:
        """A gold call matches if some model call has the same name and all of the
        gold's argument key/values (model may add optional args)."""
        for mc in model_calls:
            if mc["name"] != gold["name"]:
                continue
            margs = mc["args"] if isinstance(mc["args"], dict) else {}
            if all(k in margs and _norm(margs[k]) == _norm(v) for k, v in gold["args"].items()):
                return True
        return False

    def score(self, task: Task, output: str) -> dict:
        model_calls = _parse_model_calls(output)
        gold = task.meta["gold"]
        if not model_calls:
            return {"passed": False, "fail_reason": "no_call_parsed"}
        ok = len(model_calls) >= len(gold) and all(self._match(g, model_calls) for g in gold)
        return {"passed": ok, "fail_reason": None if ok else "wrong_call"}
