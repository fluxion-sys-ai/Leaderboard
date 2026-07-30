"""Shared multiple-choice answer extraction (used by mmlu_pro + gpqa).

One canonical letter-picker so every MCQ benchmark grades the same way: prefer an
explicit "the answer is (X)", else fall back to the last standalone letter. Only
letters within the first `n_options` count as valid.
"""
from __future__ import annotations
import re
import string


def extract_letter(text: str, n_options: int) -> str | None:
    """Pull the chosen option letter (A-…) from a model's answer, or None."""
    valid = set(string.ascii_uppercase[:n_options])
    # strongest signal: "answer is (C)" / "answer: C"
    m = re.findall(r"answer\s*(?:is|:)?\s*\(?([A-Z])\)?", text, flags=re.I)
    if m and m[-1].upper() in valid:
        return m[-1].upper()
    # fallback: a lone parenthesised/bare letter near the end
    m = re.findall(r"\(([A-Z])\)|\b([A-Z])\b(?=[\.\)\s]|$)", text)
    letters = [a or b for a, b in m if (a or b) in valid]
    return letters[-1] if letters else None
