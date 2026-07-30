"""Sandboxed code executor — runs model-generated code against tests, safely.

Coding benchmarks (HumanEval+, LiveCodeBench) require EXECUTING untrusted output.
We never run it on the host directly: each candidate runs in a separate process,
in a throwaway temp dir, under CPU + memory + file-size limits and a wall-clock
timeout. Returns (passed, reason) — reason is pass / fail / timeout / error.

This is a pragmatic sandbox for benchmark code (not a hostile-adversary jail):
resource caps + process isolation + timeout, which is what the standard code-eval
harnesses use. Network is not namespaced away, so only run trusted benchmark sets.
"""
from __future__ import annotations
import os
import resource
import subprocess
import tempfile

CPU_SECONDS = 8          # hard CPU cap per candidate
DATA_BYTES = 4 * 1024 * 1024 * 1024   # 4 GB heap cap (RLIMIT_DATA, not AS —
                         # capping virtual address space breaks Python/numpy startup)
WALL_TIMEOUT = 12        # wall-clock kill (catches sleeps/deadlocks the CPU cap misses)


def _limit():
    """preexec_fn: cap CPU, heap, and file size in the child before exec."""
    resource.setrlimit(resource.RLIMIT_CPU, (CPU_SECONDS, CPU_SECONDS))
    try:
        resource.setrlimit(resource.RLIMIT_DATA, (DATA_BYTES, DATA_BYTES))
    except (ValueError, OSError):
        pass
    resource.setrlimit(resource.RLIMIT_FSIZE, (10 * 1024 * 1024, 10 * 1024 * 1024))


def run_program(source: str, stdin: str | None = None) -> tuple[bool, str]:
    """Run a self-contained Python program. Passes iff it exits 0 in time."""
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "prog.py")
        with open(path, "w") as f:
            f.write(source)
        try:
            p = subprocess.run(
                ["python3", path], cwd=d, input=stdin, capture_output=True, text=True,
                timeout=WALL_TIMEOUT, preexec_fn=_limit,
            )
        except subprocess.TimeoutExpired:
            return False, "timeout"
        if p.returncode == 0:
            return True, "pass"
        # distinguish assertion/wrong-answer failures from crashes for the breakdown
        err = (p.stderr or "").strip().splitlines()
        tag = err[-1][:80] if err else "nonzero_exit"
        return False, "fail" if "AssertionError" in (p.stderr or "") else f"error:{tag}"


def run_io(source: str, stdin: str) -> tuple[str, bool, str]:
    """Run a program with stdin, capture stdout. For stdin/stdout-judged problems
    (LiveCodeBench). Returns (stdout, crashed_ok, reason)."""
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "prog.py")
        with open(path, "w") as f:
            f.write(source)
        try:
            p = subprocess.run(
                ["python3", path], cwd=d, input=stdin, capture_output=True, text=True,
                timeout=WALL_TIMEOUT, preexec_fn=_limit,
            )
        except subprocess.TimeoutExpired:
            return "", False, "timeout"
        if p.returncode != 0:
            return p.stdout or "", False, "runtime_error"
        return p.stdout or "", True, "ran"
