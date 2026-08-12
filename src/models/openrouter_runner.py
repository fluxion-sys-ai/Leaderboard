"""OpenRouter runner — the full-precision ceiling, run over an API (no local GPU).

The frontier-30B comparison tab needs the models at their VENDOR-RECOMMENDED
sampling and, where possible, at FULL precision (bf16) to validate against
published numbers. A 30B in bf16 is ~60 GB and won't fit the 40 GB card, so we
don't host it — we call it over OpenRouter's OpenAI-compatible endpoint (the same
one the judges already use). The weights run on OpenRouter's providers; nothing
loads locally.

THE CATCH — precision is per-provider. Most OpenRouter providers serve fp8/fp4,
not bf16, so every model here pins a `provider` block (quantizations + order +
allow_fallbacks). If you don't pin it you may benchmark an fp8 endpoint and think
it's full precision. See RECOMMENDED_PARAMS.md and MIGRATION.md for the verified
per-model routing; true bf16 exists only for Muse Glimmer + Gemma-4-31B — both
Qwen models are fp8-ceiling (labelled as such on the tab, NOT "full precision").

This runner is deliberately OFF the greedy board: it's for the separate
`configs/models_full.yaml` + the comparison tab only.
"""
from __future__ import annotations
import json
import os
import time
import urllib.error
import urllib.request

from .base import ModelRunner, GenResult

ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"

# Reasoning models spend thousands of tokens in the reasoning channel before the
# answer. Benchmark max_tokens are tuned for non-reasoning greedy models (~1-3k)
# and truncate them mid-reasoning (finish_reason=length, empty content) -> the
# answer is lost and the task scores 0. Floor the budget for reasoning models so
# the answer survives. max_tokens is headroom, NOT a sampling param -> recommended
# sampling stays untouched.
REASONING_MIN_TOKENS = 32768
# Same secret the judges read (gitignored). Resolved at _start, never at import,
# so importing the registry never requires the key (llamacpp runs must not break
# just because .openrouter_key is absent).
from ..utils.helpers import REPO_ROOT
KEY_PATH = REPO_ROOT / ".openrouter_key"

# Sampling params we forward when present in cfg. Anything provider-specific or
# future (e.g. Gemma's think toggle) goes through cfg["extra_body"] — no code change.
_PASS_PARAMS = ("temperature", "top_p", "top_k", "min_p", "presence_penalty",
                "frequency_penalty", "repetition_penalty")


class OpenRouterRunner(ModelRunner):
    """Remote, stateless: no server to launch, no weights on disk, no VRAM."""

    # --- local telemetry is meaningless for a remote model → stub it -----------
    def __enter__(self) -> "OpenRouterRunner":
        # Skip the VramSampler the base sets up: nothing runs on this GPU.
        self._start()
        return self

    def __exit__(self, *exc) -> None:
        self._stop()

    @property
    def peak_vram_mb(self):  # nothing loads locally
        return None

    # --- lifecycle -------------------------------------------------------------
    def _start(self) -> None:
        if not KEY_PATH.exists():
            raise FileNotFoundError(
                f"OpenRouter key not found at {KEY_PATH}. Create it (one line, the "
                "OpenRouter API key) before running the full-precision tab."
            )
        self._key = KEY_PATH.read_text().strip()
        self.gguf_bytes = 0        # remote — no local weights
        self.load_seconds = 0.0    # nothing to load
        if not self.cfg.get("model_slug"):
            raise KeyError(f"model '{self.name}' needs a 'model_slug' for the OpenRouter runner")
        if not self.cfg.get("provider"):
            # Not fatal, but unpinned routing can silently drop to a lower precision —
            # which invalidates a "full precision" claim. Warn loudly.
            print(f"[openrouter] WARNING: model '{self.name}' has no provider pin — "
                  "precision/provider is unpinned and may not be bf16.", flush=True)
        self._warned_providers: set[str] = set()

    def _stop(self) -> None:
        pass  # stateless

    # --- generation ------------------------------------------------------------
    def _generate(self, messages: list[dict], max_tokens: int) -> GenResult:
        effective_max = max(max_tokens, REASONING_MIN_TOKENS)
        body = {
            "model": self.cfg["model_slug"],
            "messages": self._with_reasoning(messages),
            "max_tokens": effective_max,
            "usage": {"include": True},   # ask providers to report token counts
        }
        for p in _PASS_PARAMS:
            if self.cfg.get(p) is not None:
                body[p] = self.cfg[p]
        if self.cfg.get("provider"):
            body["provider"] = self.cfg["provider"]        # the precision/provider pin
        if self.cfg.get("extra_body"):
            body.update(self.cfg["extra_body"])            # per-model API knobs, no code change

        payload = json.dumps(body).encode()
        req = urllib.request.Request(
            ENDPOINT, data=payload,
            headers={"Authorization": "Bearer " + self._key, "Content-Type": "application/json"},
        )
        # Resilient like the llamacpp runner: a transient API error must not kill
        # the whole sweep. Retry with backoff; on repeated failure the task scores
        # as a miss (empty output) and the run carries on.
        t0 = time.time()
        resp = None
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=900) as r:
                    resp = json.loads(r.read())
                break
            except (urllib.error.HTTPError, urllib.error.URLError, ConnectionError,
                    TimeoutError, json.JSONDecodeError):
                if attempt == 3:
                    return GenResult(text="", n_tokens=0)
                time.sleep(3 * (attempt + 1))
        total_ms = round((time.time() - t0) * 1000.0, 2)

        # An API-level error comes back 200 with an "error" object, not as an HTTP error.
        if isinstance(resp, dict) and resp.get("error") and not resp.get("choices"):
            print(f"[openrouter] {self.name}: API error {resp['error']}", flush=True)
            return GenResult(text="", n_tokens=0)

        self._audit_provider(resp)     # surface served provider + any param warnings

        choice = (resp.get("choices") or [{}])[0]
        text = (choice.get("message") or {}).get("content") or ""
        # Truncation guard: if the model ran out of budget mid-reasoning the answer
        # is cut off (finish_reason=length) and content is short/empty. Surface it
        # loudly — a run full of these is invalid, not a real low score.
        finish = choice.get("finish_reason") or choice.get("native_finish_reason")
        if finish == "length" and len(text.strip()) < 8:
            print(f"[openrouter] {self.name}: TRUNCATED (finish_reason=length, empty "
                  f"content at max_tokens={effective_max}) — answer lost to reasoning.",
                  flush=True)
        usage = resp.get("usage") or {}
        return GenResult(
            text=text,
            n_tokens=usage.get("completion_tokens", 0),
            prompt_tokens=usage.get("prompt_tokens", 0),
            total_ms=total_ms,   # wall-clock; the API gives no prefill/decode split
        )

    # --- helpers ---------------------------------------------------------------
    def _with_reasoning(self, messages: list[dict]) -> list[dict]:
        """Inject Muse-Glimmer-style 'Reasoning strength: <x>' into the system prompt.

        Muse sets reasoning strength via the system prompt (per its card). If
        cfg['reasoning_strength'] is set we add that line; if a system message
        already exists we append to it, otherwise we prepend one. No-op for models
        that don't use it (Gemma/Qwen leave it unset).
        """
        strength = self.cfg.get("reasoning_strength")
        if not strength:
            return messages
        line = f"Reasoning strength: {strength}"
        out = [dict(m) for m in messages]
        for m in out:
            if m.get("role") == "system":
                m["content"] = (m.get("content", "").rstrip() + "\n" + line).strip()
                return out
        return [{"role": "system", "content": line}] + out

    def _audit_provider(self, resp: dict) -> None:
        """Log the serving provider once, plus any OpenRouter param warnings.

        OpenRouter does NOT reliably echo which sampling params a provider dropped,
        so we can't detect a silenced top_k directly. Instead we log the provider
        that actually served (once each) so top_k support can be verified against
        it, and surface any explicit `warnings` the API does return.
        """
        if not isinstance(resp, dict):
            return
        for w in resp.get("warnings") or []:
            print(f"[openrouter] {self.name}: warning {w}", flush=True)
        provider = resp.get("provider")
        if provider and self.cfg.get("top_k") is not None and provider not in self._warned_providers:
            self._warned_providers.add(provider)
            print(f"[openrouter] {self.name}: served by '{provider}'. top_k was requested "
                  "but not all providers honor it — verify it applied for this provider.",
                  flush=True)
