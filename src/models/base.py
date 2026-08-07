"""The uniform model interface.

Everything upstream (benchmarks, the CLI) talks to a `ModelRunner`, never to a
specific engine. Swapping llama.cpp for vLLM later means adding one subclass —
nothing else changes. That's the whole reason this abstraction exists.
"""
from __future__ import annotations
import abc
from dataclasses import dataclass


@dataclass
class GenResult:
    """One model response plus ALL telemetry we can capture for it.

    We record everything per generation, not just the answer, so nothing has to
    be re-run to compute a metric later. Fields group into: text, token counts,
    speed, latency, and (optional) speculative-decoding stats.
    """
    text: str
    n_tokens: int              # completion tokens out
    prompt_tokens: int = 0     # prompt tokens in (context size actually used)
    # Speed — the prefill/decode columns.
    prefill_tps: float = 0.0   # prompt-eval throughput (tok/s)
    decode_tps: float = 0.0    # generation throughput (tok/s)
    # Latency — prefill_ms ≈ time-to-first-token (the TTFT metric).
    prefill_ms: float = 0.0
    decode_ms: float = 0.0
    total_ms: float = 0.0
    # Speculative decoding — only populated when a drafter is attached (else None).
    # per_pos_acceptance: accepted-token rate at each draft position; tau: mean
    # accepted tokens per verification round; accept_rate: accepted/drafted;
    # fire_rate/coverage: how often an n-gram-style drafter actually fires.
    spec: dict | None = None


class ModelRunner(abc.ABC):
    """Load a model once, answer many chat prompts, then shut down cleanly.

    Concrete runners implement `_start`, `_generate`, and `_stop`. The context
    manager guarantees the engine is torn down even if a benchmark throws.
    """

    def __init__(self, name: str, cfg: dict):
        self.name = name          # short alias, e.g. "phi-4-mini-instruct"
        self.cfg = cfg            # merged defaults + per-model config
        # Resource telemetry, filled by _start / the VRAM sampler.
        self.load_seconds = 0.0   # time to load the model + become ready
        self.gguf_bytes = 0       # on-disk size of the quantized weights
        self._vram = None

    @property
    def peak_vram_mb(self) -> float:
        """Live peak GPU memory so far — readable mid-run (not just at teardown)."""
        return round(self._vram.peak_mb, 1) if self._vram else 0.0

    def __enter__(self) -> "ModelRunner":
        from ..utils.helpers import VramSampler
        self._vram = VramSampler().start()   # sample across load + all benchmarks
        self._start()
        return self

    def __exit__(self, *exc) -> None:
        if self._vram:
            self._vram.stop()
        self._stop()

    def generate(self, messages: list[dict], max_tokens: int | None = None) -> GenResult:
        """Run one chat turn. `messages` is OpenAI-style [{role, content}, ...]."""
        return self._generate(messages, max_tokens or self.cfg["max_tokens"])

    # --- engine-specific hooks ------------------------------------------------
    @abc.abstractmethod
    def _start(self) -> None: ...

    @abc.abstractmethod
    def _generate(self, messages: list[dict], max_tokens: int) -> GenResult: ...

    @abc.abstractmethod
    def _stop(self) -> None: ...
