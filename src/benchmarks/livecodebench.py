"""LiveCodeBench benchmark — Coding (code generation) dimension, PRIMARY.

Contamination-resistant competitive-programming problems (timestamped, so we
filter to a post-cutoff window). The model writes a full program that reads
stdin and writes stdout; we run it against public + hidden test cases. Judge-free.

Scope note: we evaluate the STDIN/STDOUT problems (AtCoder/Codeforces — the bulk
of the set). LeetCode-style `functional` problems need a different call harness
and are skipped for now (logged as coverage). Category = difficulty.

The HF repo ships a (now-unsupported) loader script, so we read the jsonl release
files directly. Hidden tests are base64 -> zlib -> pickle encoded.
"""
from __future__ import annotations
import base64
import json
import pickle
import zlib

from huggingface_hub import hf_hub_download

from .base import Benchmark, Task
from ..evaluators.code_exec import run_io

RELEASE_FILE = "test5.jsonl"          # v5: problems through Jan 2025


def _decode_private(blob: str) -> list:
    dec = zlib.decompress(base64.b64decode(blob))
    try:
        val = json.loads(dec)
    except Exception:
        val = pickle.loads(dec)
    if isinstance(val, str):        # sometimes double-encoded (JSON string of JSON)
        val = json.loads(val)
    return val


class LiveCodeBench(Benchmark):
    name = "livecodebench"
    dimension = "Coding"

    def load(self) -> list[Task]:
        after = self.cfg.get("after_date", "2024-08")   # contamination cutoff (YYYY-MM)
        path = hf_hub_download("livecodebench/code_generation_lite",
                               self.cfg.get("release_file", RELEASE_FILE), repo_type="dataset")
        tasks = []
        for line in open(path):
            r = json.loads(line)
            if r["contest_date"][:7] < after:
                continue
            pub = json.loads(r["public_test_cases"])
            if not pub or pub[0]["testtype"] != "stdin":    # stdin problems only, for now
                continue
            tests = pub + _decode_private(r["private_test_cases"])
            tests = [{"input": t["input"], "output": t["output"]} for t in tests]
            tasks.append(Task(
                task_id=str(r["question_id"]),
                prompt=r["question_content"],
                meta={"tests": tests, "category": r["difficulty"]},
            ))
        return tasks

    def build_messages(self, task: Task) -> list[dict]:
        return [{"role": "user",
                 "content": task.prompt + "\n\nWrite a complete Python program that reads "
                            "from standard input and writes the answer to standard output. "
                            "Return only the program in a ```python code block."}]

    def score(self, task: Task, output: str) -> dict:
        import re
        blocks = re.findall(r"```(?:python)?[ \t]*\n?(.*?)```", output, flags=re.S)
        code = (blocks[-1] if blocks else output).rstrip()
        for t in task.meta["tests"]:
            stdout, ok, reason = run_io(code, t["input"])
            if not ok:
                return {"passed": False, "fail_reason": reason}
            if stdout.strip() != t["output"].strip():
                return {"passed": False, "fail_reason": "wrong_output"}
        return {"passed": True, "fail_reason": None}
