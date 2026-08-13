"""llama.cpp runner — serves a quantized GGUF and answers chat prompts.

We drive `llama-server` over its OpenAI-compatible HTTP API rather than shelling
out to `llama-cli` per prompt: it keeps the model resident (load once), applies
the model's own chat template, and mirrors how edge inference actually runs
(a local server on localhost). One server per model, torn down when done —
consistent with the solo-GPU rule (one job at a time).
"""
from __future__ import annotations
import os
import re
import subprocess
import time
import urllib.request
import urllib.error
import json

from .base import ModelRunner, GenResult

# llama-server's print_timing lines (emitted per request when a drafter is attached):
#   acc per pos = (1.000, 0.800, 0.400, ...)          <- PER-POSITION acceptance
#   draft acceptance = 0.625 ( 10 accepted / 16 generated), mean len = 6.00
_ACC_POS = re.compile(r"acc per pos = \(([^)]*)\)")
_DRAFT = re.compile(
    r"draft acceptance = ([\d.]+) \(\s*(\d+) accepted /\s*(\d+) generated\), mean len =\s*([\d.]+)")

# Path to the llama.cpp binaries. Override with LLAMACPP_BIN; confirmed at start.
LLAMACPP_BIN = os.environ.get("LLAMACPP_BIN", "/home/aliixh/llama.cpp")
PORT = int(os.environ.get("LLAMACPP_PORT", "8081"))


class LlamaCppRunner(ModelRunner):
    def _start(self) -> None:
        server = os.path.join(LLAMACPP_BIN, "llama-server")
        if not os.path.exists(server):
            raise FileNotFoundError(
                f"llama-server not found at {server}. Set LLAMACPP_BIN to your "
                "llama.cpp build directory."
            )
        gguf = self.cfg["gguf_path"]          # resolved local path (see run_benchmark)
        self.gguf_bytes = os.path.getsize(gguf)   # on-disk weight size
        cmd = [
            server, "-m", gguf,
            "-c", str(self.cfg["n_ctx"]),
            "-ngl", "999",                    # offload all layers to GPU
            "--host", "127.0.0.1", "--port", str(PORT),
            "--no-webui",
        ]
        # no_think: run dual-mode Qwen3/3.5 models in direct-answer mode. Very verbose
        # thinking models burn the whole token budget inside <think> and truncate before
        # the answer (empty output) — disabling thinking makes them fast + complete. This
        # is a legitimate, reported config for these explicitly dual-mode models.
        if self.cfg.get("no_think"):
            cmd += ["--chat-template-kwargs", '{"enable_thinking": false}']
        elif self.cfg.get("template_kwargs"):
            # custom chat-template-kwargs for models that DON'T use enable_thinking —
            # e.g. gpt-oss (harmony format) wants {"reasoning_effort": "low"} to keep
            # reasoning short so it reaches the final channel before the token cap.
            import json as _json
            cmd += ["--chat-template-kwargs", _json.dumps(self.cfg["template_kwargs"])]
        # gpt-oss/harmony: '--reasoning off' disables the analysis channel so the answer lands in
        # message.content (the harness reads only content). reasoning_effort was a no-op for the
        # empty-final bug — this is the actual lever. Verified 0% empty on an 8-task bfcl probe.
        if self.cfg.get("reasoning_off"):
            cmd += ["--reasoning", "off"]
        # Speculative-decoding mode: attach a draft model → llama-server logs
        # per-position acceptance we parse back out. Only when cfg['draft'] is set.
        self._spec = bool(self.cfg.get("draft"))
        if self._spec:
            cmd += ["-md", self.cfg["draft"], "--spec-draft-n-max",
                    str(self.cfg.get("draft_max", 8))]
        # Server logs go to a file so they don't pollute the benchmark output.
        self._log_path = f"/tmp/llamacpp_{self.name}.log"
        self._log = open(self._log_path, "w")
        self._spec_off = 0                    # byte offset for incremental log parsing
        t0 = time.time()
        self._proc = subprocess.Popen(cmd, stdout=self._log, stderr=subprocess.STDOUT)
        self._wait_healthy()
        self.load_seconds = round(time.time() - t0, 1)   # launch → model ready

    def _wait_healthy(self, timeout_s: int = 300) -> None:
        """Poll /health until the model is loaded (GGUFs can take a while)."""
        url = f"http://127.0.0.1:{PORT}/health"
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            if self._proc.poll() is not None:
                raise RuntimeError(f"llama-server died on startup; see /tmp/llamacpp_{self.name}.log")
            try:
                with urllib.request.urlopen(url, timeout=3) as r:
                    if r.status == 200:
                        return
            except (urllib.error.URLError, ConnectionError):
                time.sleep(2)
        raise TimeoutError(f"llama-server not healthy after {timeout_s}s")

    def _generate(self, messages: list[dict], max_tokens: int) -> GenResult:
        # Thinking models need a floor so a small per-benchmark cap (e.g. pinchbench's
        # 1024) doesn't truncate mid-reasoning. Only applies when thinking is ON
        # (frontier Q4: template_kwargs.enable_thinking) — greedy/no_think is untouched.
        if max_tokens and (self.cfg.get("template_kwargs") or {}).get("enable_thinking"):
            max_tokens = max(max_tokens, 32768)
        body = {
            "messages": messages,
            "temperature": self.cfg["temperature"],
            "max_tokens": max_tokens,
        }
        # Forward vendor-recommended sampling knobs WHEN SET (frontier Q4 tab).
        # The greedy board leaves these unset → payload unchanged (pure greedy).
        for k in ("top_p", "top_k", "min_p", "presence_penalty"):
            if self.cfg.get(k) is not None:
                body[k] = self.cfg[k]
        payload = json.dumps(body).encode()
        req = urllib.request.Request(
            f"http://127.0.0.1:{PORT}/v1/chat/completions",
            data=payload, headers={"Content-Type": "application/json"},
        )
        # Resilient: a single transient server error must NOT kill the whole run.
        # Retry a few times; if it keeps failing, return an empty answer (that one
        # task scores as a miss) and carry on.
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
        text = resp["choices"][0]["message"]["content"]
        usage = resp.get("usage", {})
        # llama-server reports a rich `timings` block per request — capture all of it.
        t = resp.get("timings", {})
        prefill_ms = t.get("prompt_ms", 0.0)
        decode_ms = t.get("predicted_ms", 0.0)
        return GenResult(
            text=text,
            n_tokens=usage.get("completion_tokens", t.get("predicted_n", 0)),
            prompt_tokens=usage.get("prompt_tokens", t.get("prompt_n", 0)),
            prefill_tps=round(t.get("prompt_per_second", 0.0), 2),
            decode_tps=round(t.get("predicted_per_second", 0.0), 2),
            prefill_ms=round(prefill_ms, 2),          # ~ time-to-first-token
            decode_ms=round(decode_ms, 2),
            total_ms=round(prefill_ms + decode_ms, 2),
            spec=self._drain_spec() if self._spec else None,
        )

    def _drain_spec(self) -> dict | None:
        """Read new server-log bytes and pull this request's spec-decode stats.

        Parses the `acc per pos = (...)` and `draft acceptance = ...` lines that
        llama-server prints per request when a drafter is attached. Batch-1
        sequential runs mean the newest block belongs to the just-finished request.
        """
        self._log.flush()
        try:
            with open(self._log_path) as f:
                f.seek(self._spec_off)
                chunk = f.read()
                self._spec_off = f.tell()
        except OSError:
            return None
        spec: dict = {}
        pos = _ACC_POS.findall(chunk)
        if pos:
            spec["per_pos_acceptance"] = [float(x) for x in pos[-1].split(",") if x.strip()]
        d = _DRAFT.findall(chunk)
        if d:
            rate, acc, gen, mean = d[-1]
            spec.update({"accept_rate": float(rate), "draft_n_accepted": int(acc),
                         "draft_n": int(gen), "tau": float(mean)})
        return spec or None

    def _stop(self) -> None:
        if getattr(self, "_proc", None):
            self._proc.terminate()
            try:
                self._proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        if getattr(self, "_log", None):
            self._log.close()
