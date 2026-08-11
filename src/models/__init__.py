"""Model-runner registry: name (from models.yaml) -> ModelRunner subclass."""
from .base import ModelRunner, GenResult
from .llamacpp_runner import LlamaCppRunner
from .openrouter_runner import OpenRouterRunner

RUNNERS = {
    "llamacpp": LlamaCppRunner,
    "openrouter": OpenRouterRunner,   # full-precision (bf16) ceiling over the API — frontier-30B tab
    # "vllm": VllmRunner,   # local full-precision alternative (needs an 80GB card)
}


def get_runner(name: str, model_name: str, cfg: dict) -> ModelRunner:
    if name not in RUNNERS:
        raise KeyError(f"unknown runner '{name}'. Known: {list(RUNNERS)}")
    return RUNNERS[name](model_name, cfg)


# Public surface: the registry + the base types a runner implements/returns.
__all__ = ["RUNNERS", "get_runner", "ModelRunner", "GenResult"]
