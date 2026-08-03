"""Model-runner registry: name (from models.yaml) -> ModelRunner subclass."""
from .base import ModelRunner, GenResult
from .llamacpp_runner import LlamaCppRunner

RUNNERS = {
    "llamacpp": LlamaCppRunner,
    # "vllm": VllmRunner,   # add later for the full-precision ceiling comparison
}


def get_runner(name: str, model_name: str, cfg: dict) -> ModelRunner:
    if name not in RUNNERS:
        raise KeyError(f"unknown runner '{name}'. Known: {list(RUNNERS)}")
    return RUNNERS[name](model_name, cfg)


# Public surface: the registry + the base types a runner implements/returns.
__all__ = ["RUNNERS", "get_runner", "ModelRunner", "GenResult"]
