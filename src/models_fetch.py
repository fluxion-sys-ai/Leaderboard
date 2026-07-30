"""Resolve a model's quantized GGUF: download from HuggingFace, cache, confirm.

We never assume a repo/file exists from memory — we resolve it here, at run time,
and fail loudly with the exact repo id if it's wrong. Weights are cached under
models/ (gitignored), so a second run is instant.
"""
from __future__ import annotations
import glob
import pathlib

from huggingface_hub import hf_hub_download, list_repo_files

from .utils.helpers import REPO_ROOT

MODELS_DIR = REPO_ROOT / "models"


def ensure_gguf(model_name: str, gguf: dict) -> str:
    """Resolve a GGUF to a local path.

    gguf = {local: /path}         -> use a pre-downloaded file (edge/offline case)
         | {repo, file(glob)}     -> download from HuggingFace + cache
    """
    if gguf.get("local"):
        path = gguf["local"]
        if not pathlib.Path(path).exists():
            raise FileNotFoundError(f"local GGUF not found: {path}")
        return path

    dest = MODELS_DIR / model_name
    dest.mkdir(parents=True, exist_ok=True)

    # already downloaded?
    local = glob.glob(str(dest / "*.gguf"))
    if local:
        return local[0]

    # find the file in the repo that matches the requested pattern (e.g. *Q4_K_M.gguf)
    pattern = gguf["file"].replace("*", "")
    matches = [f for f in list_repo_files(gguf["repo"]) if f.endswith(".gguf") and pattern in f]
    if not matches:
        raise FileNotFoundError(
            f"No GGUF matching '{gguf['file']}' in repo '{gguf['repo']}'. "
            "Check the repo id / quant on HuggingFace."
        )
    path = hf_hub_download(repo_id=gguf["repo"], filename=matches[0], local_dir=str(dest))
    return path
