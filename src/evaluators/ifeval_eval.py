"""IFEval scorer — verifiable instruction-following, no LLM judge.

IFEval gives each prompt a list of `instruction_id`s (e.g. "punctuation:no_comma")
with kwargs (e.g. num_words=100, relation="at least"). Each instruction is a
programmatic, deterministic check on the response. We report two things per task:
  - strict_pass: ALL instructions satisfied (the headline IFEval metric)
  - instr_pass / instr_total: instruction-level fraction (partial credit)

Checkers live in the CHECKERS registry keyed by instruction_id. Adding support
for a new instruction type is one function + one registry entry. Instruction ids
we don't yet implement are recorded as "unsupported" so coverage stays honest —
they are NOT silently counted as passed.
"""
from __future__ import annotations
import json
import re

from .base import Evaluator

try:
    from langdetect import detect as _detect_lang   # optional; language checks need it
except Exception:                                    # not installed → language checks unsupported
    _detect_lang = None

# ── individual constraint checkers ───────────────────────────────────────────
# Each takes (response_text, kwargs) and returns True/False.

def _word_count(text: str) -> int:
    return len(re.findall(r"\b\w+\b", text))

def _sentences(text: str) -> list[str]:
    return [s for s in re.split(r"(?<=[.!?])\s+", text.strip()) if s]

def _relation_ok(value: int, relation: str, target: int) -> bool:
    return value >= target if relation == "at least" else value <= target


def c_number_words(text, kw):
    return _relation_ok(_word_count(text), kw.get("relation", "at least"), kw["num_words"])

def c_number_sentences(text, kw):
    return _relation_ok(len(_sentences(text)), kw.get("relation", "at least"), kw["num_sentences"])

def c_number_paragraphs(text, kw):
    paras = [p for p in re.split(r"\n\s*\n", text.strip()) if p.strip()]
    return len(paras) == kw["num_paragraphs"]

def c_keyword_existence(text, kw):
    low = text.lower()
    return all(k.lower() in low for k in kw["keywords"])

def c_keyword_frequency(text, kw):
    n = len(re.findall(rf"\b{re.escape(kw['keyword'].lower())}\b", text.lower()))
    return _relation_ok(n, kw.get("relation", "at least"), kw["frequency"])

def c_forbidden_words(text, kw):
    low = text.lower()
    return not any(re.search(rf"\b{re.escape(w.lower())}\b", low) for w in kw["forbidden_words"])

def c_no_comma(text, kw):
    return "," not in text

def c_all_capital(text, kw):
    return text.upper() == text and any(ch.isalpha() for ch in text)

def c_all_lowercase(text, kw):
    return text.lower() == text and any(ch.isalpha() for ch in text)

def c_end_checker(text, kw):
    return text.strip().endswith(kw["end_phrase"].strip())

def c_quotation(text, kw):
    t = text.strip()
    return len(t) >= 2 and t[0] == '"' and t[-1] == '"'

def c_number_bullets(text, kw):
    bullets = re.findall(r"^\s*[\*\-]\s+", text, flags=re.MULTILINE)
    return len(bullets) == kw["num_bullets"]

def c_number_highlights(text, kw):
    # markdown highlights: *word* or **word**
    highlights = re.findall(r"\*+[^*\n]+\*+", text)
    return len(highlights) >= kw["num_highlights"]

def c_postscript(text, kw):
    return kw["postscript_marker"].lower() in text.lower()

def c_placeholders(text, kw):
    return len(re.findall(r"\[[^\]]+\]", text)) >= kw["num_placeholders"]

def c_title(text, kw):
    return bool(re.search(r"<<[^>\n]+>>", text))

def c_letter_frequency(text, kw):
    n = text.lower().count(kw["letter"].lower())
    return _relation_ok(n, kw.get("let_relation", "at least"), kw["let_frequency"])

def c_capital_word_frequency(text, kw):
    caps = sum(1 for w in re.findall(r"\b\w+\b", text) if w.isupper() and any(c.isalpha() for c in w))
    return _relation_ok(caps, kw.get("capital_relation", "at least"), kw["capital_frequency"])

def c_nth_paragraph_first_word(text, kw):
    paras = [p.strip() for p in re.split(r"\n\s*\n", text.strip()) if p.strip()]
    n = kw["nth_paragraph"]
    if len(paras) < kw.get("num_paragraphs", n) or n > len(paras):
        return False
    first = re.findall(r"\b\w+\b", paras[n - 1])
    return bool(first) and first[0].lower() == kw["first_word"].lower()

def c_multiple_sections(text, kw):
    n = len(re.findall(re.escape(kw["section_spliter"]), text))
    return n >= kw["num_sections"]

def c_repeat_prompt(text, kw):
    want = " ".join(kw["prompt_to_repeat"].split()).lower()
    got = " ".join(text.split()).lower()
    return got.startswith(want)

def c_two_responses(text, kw):
    parts = [p for p in text.split("******") if p.strip()]
    return "******" in text and len(parts) == 2

def c_constrained_response(text, kw):
    options = {"my answer is yes.", "my answer is no.", "my answer is maybe."}
    return text.strip().lower() in options

def c_json_format(text, kw):
    body = re.sub(r"^```(?:json)?|```$", "", text.strip(), flags=re.MULTILINE).strip()
    try:
        json.loads(body)
        return True
    except Exception:
        return False

def c_response_language(text, kw):
    if _detect_lang is None:
        raise RuntimeError("langdetect not installed")   # -> recorded as unsupported
    try:
        return _detect_lang(text) == kw["language"]
    except Exception:
        return False


# instruction_id -> checker. Full IFEval instruction set (language needs langdetect).
CHECKERS = {
    "length_constraints:number_words": c_number_words,
    "length_constraints:number_sentences": c_number_sentences,
    "length_constraints:number_paragraphs": c_number_paragraphs,
    "length_constraints:nth_paragraph_first_word": c_nth_paragraph_first_word,
    "keywords:existence": c_keyword_existence,
    "keywords:frequency": c_keyword_frequency,
    "keywords:forbidden_words": c_forbidden_words,
    "keywords:letter_frequency": c_letter_frequency,
    "punctuation:no_comma": c_no_comma,
    "change_case:english_capital": c_all_capital,
    "change_case:english_lowercase": c_all_lowercase,
    "change_case:capital_word_frequency": c_capital_word_frequency,
    "startend:end_checker": c_end_checker,
    "startend:quotation": c_quotation,
    "detectable_format:number_bullet_lists": c_number_bullets,
    "detectable_format:number_highlighted_sections": c_number_highlights,
    "detectable_format:multiple_sections": c_multiple_sections,
    "detectable_format:constrained_response": c_constrained_response,
    "detectable_format:json_format": c_json_format,
    "detectable_format:title": c_title,
    "detectable_content:postscript": c_postscript,
    "detectable_content:number_placeholders": c_placeholders,
    "combination:repeat_prompt": c_repeat_prompt,
    "combination:two_responses": c_two_responses,
    "language:response_language": c_response_language,
}


class IFEvalEvaluator(Evaluator):
    def score(self, output: str, meta: dict) -> dict:
        ids = meta["instruction_id_list"]
        kwargs = meta["kwargs"]
        results, unsupported, by_instruction = [], [], []
        for iid, kw in zip(ids, kwargs):
            checker = CHECKERS.get(iid)
            if checker is None:
                unsupported.append(iid)
                continue
            try:
                ok = bool(checker(output, {k: v for k, v in kw.items() if v is not None}))
            except Exception:
                ok = False              # a malformed/uncheckable response fails
            results.append(ok)
            by_instruction.append((iid, ok))   # keep type→result for per-type splits
        total = len(results)
        # STRICT rule: full pass requires ALL instructions checked AND all satisfied.
        # If any instruction is unsupported we could not verify the task, so it does
        # NOT get credit (conservative — never inflate by grading a partial subset).
        return {
            "passed": total > 0 and not unsupported and all(results),
            "instr_pass": sum(results),
            "instr_total": total,
            "unsupported": unsupported,                    # honesty: what we couldn't check
            "by_instruction": by_instruction,              # (type, ok) for per-type splits
        }
