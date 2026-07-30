"""Shared plumbing: config loading, JSON IO, and the resume cache.

Kept deliberately tiny and dependency-light so every other module can lean on it
without pulling in heavy imports.
"""
from __future__ import annotations
import json
import pathlib
import subprocess
import threading
import time
from typing import Any

import yaml


class VramSampler:
    """Background thread that polls nvidia-smi and remembers peak GPU memory (MiB).

    Solo-GPU rule means one job owns the card, so total used ≈ this run's usage.
    Degrades to 0.0 if nvidia-smi is absent (e.g. CPU-only box) — never raises.
    """

    def __init__(self, interval_s: float = 0.5):
        self.interval_s = interval_s
        self.peak_mb = 0.0
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def _poll(self) -> None:
        while not self._stop.is_set():
            try:
                out = subprocess.check_output(
                    ["nvidia-smi", "--query-gpu=memory.used",
                     "--format=csv,noheader,nounits"], text=True, timeout=3)
                used = max(float(x) for x in out.split() if x.strip())
                self.peak_mb = max(self.peak_mb, used)
            except Exception:
                pass  # no GPU / nvidia-smi missing — leave peak at 0
            time.sleep(self.interval_s)

    def start(self) -> "VramSampler":
        self._thread = threading.Thread(target=self._poll, daemon=True)
        self._thread.start()
        return self

    def stop(self) -> float:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
        return round(self.peak_mb, 1)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
RESULTS = REPO_ROOT / "results"


def load_yaml(path: str | pathlib.Path) -> dict:
    """Read a YAML config file into a plain dict."""
    with open(path) as f:
        return yaml.safe_load(f)


def raw_path(model: str, benchmark: str, root: pathlib.Path = RESULTS) -> pathlib.Path:
    """<root>/raw/<model>/<benchmark>.jsonl — one file per (model, benchmark).

    `root` lets the spec-decode pass write to results/spec/ instead of results/,
    keeping it separate from the capability cells.
    """
    return root / "raw" / model / f"{benchmark}.jsonl"


def scored_path(model: str, benchmark: str, root: pathlib.Path = RESULTS) -> pathlib.Path:
    """<root>/scored/<model>/<benchmark>.json — the metric file for one cell."""
    return root / "scored" / model / f"{benchmark}.json"


def write_jsonl(path: pathlib.Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


def read_jsonl(path) -> list[dict]:
    path = pathlib.Path(path)                       # accept str or Path
    if not path.exists():
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def write_json(path: pathlib.Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2))


def done_task_ids(model: str, benchmark: str, root: pathlib.Path = RESULTS) -> set[str]:
    """Task ids already generated — lets a crashed run resume instead of redoing.

    Edge models are slow, so never regenerate an answer we already have.
    """
    return {r["task_id"] for r in read_jsonl(raw_path(model, benchmark, root)) if "task_id" in r}


def append_jsonl(path: pathlib.Path, row: dict) -> None:
    """Append a single generation immediately, so progress survives a crash."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(row) + "\n")


def sample_tasks(tasks: list, n: int | None, seed: int = 42) -> list:
    """Random (reproducible) sample of tasks — never a biased first-N slice.

    If every task carries meta['category'], the sample is STRATIFIED: drawn evenly
    across categories so each is represented. Otherwise it's a plain random sample.
    A fixed seed makes the exact subset reproducible run-to-run.
    """
    import random
    from collections import defaultdict

    if n is None or n >= len(tasks):
        return list(tasks)
    rng = random.Random(seed)

    cats = [t.meta.get("category") for t in tasks]
    if all(c is not None for c in cats):                      # stratified
        groups: dict = defaultdict(list)
        for t in tasks:
            groups[t.meta["category"]].append(t)
        per = max(1, n // len(groups))
        out: list = []
        for g in groups.values():
            rng.shuffle(g)
            out.extend(g[:per])
        rng.shuffle(out)
        if len(out) > n:                                      # trim overshoot
            out = out[:n]
        elif len(out) < n:                                    # fill remainder randomly
            picked = set(id(t) for t in out)
            rest = [t for t in tasks if id(t) not in picked]
            rng.shuffle(rest)
            out.extend(rest[: n - len(out)])
        return out

    return rng.sample(list(tasks), n)                         # plain random


def strip_reasoning(text: str) -> str:
    """Remove chain-of-thought so scoring sees only the final answer.

    Reasoning models (e.g. DeepSeek-R1-Distill) wrap thinking in <think>…</think>
    and put the real answer AFTER it. Grading the raw output would unfairly fail
    them on instruction-following / format checks. We keep the full text in raw/
    and strip only at scoring time.
    """
    low = text.lower()
    close = low.rfind("</think>")
    if close != -1:                                   # answer is after the last </think>
        return text[close + len("</think>"):].strip()
    open_ = low.find("<think>")                        # truncated reasoning, no close
    return (text[:open_] if open_ != -1 else text).strip()
